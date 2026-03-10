use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

use starkprivacy_pool::pool::IPrivacyPoolDispatcher;
use starkprivacy_pool::pool::IPrivacyPoolDispatcherTrait;
use starkprivacy_compliance::sanctions::ISanctionsOracleDispatcher;
use starkprivacy_compliance::sanctions::ISanctionsOracleDispatcherTrait;
use starkprivacy_stealth::registry::IStealthRegistryDispatcher;
use starkprivacy_stealth::registry::IStealthRegistryDispatcherTrait;
use starkprivacy_bridge::epoch_manager::IEpochManagerDispatcher;
use starkprivacy_bridge::epoch_manager::IEpochManagerDispatcherTrait;
use starkprivacy_primitives::note::{Note, compute_note_commitment, compute_nullifier_v2};

fn deploy_sanctions_oracle() -> ContractAddress {
    let contract = declare("SanctionsOracle").unwrap().contract_class();
    let owner: ContractAddress = starknet::get_contract_address();
    let calldata: Array<felt252> = array![owner.into()];
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

fn deploy_pool_with_compliance(compliance: ContractAddress) -> ContractAddress {
    let contract = declare("PrivacyPool").unwrap().contract_class();
    let native_token: ContractAddress = 0.try_into().unwrap(); // zero = balance-tracking only (no ERC-20)
    let chain_id: felt252 = 'SN_SEPOLIA';
    let app_id: felt252 = 'STARKPRIVACY';
    let owner: ContractAddress = 0x999.try_into().unwrap();

    let calldata: Array<felt252> = array![
        native_token.into(), compliance.into(), chain_id, app_id, owner.into(),
    ];
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

fn deploy_stealth_registry() -> ContractAddress {
    let contract = declare("StealthRegistry").unwrap().contract_class();
    let calldata: Array<felt252> = array![];
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

fn deploy_epoch_manager() -> ContractAddress {
    let contract = declare("EpochManager").unwrap().contract_class();
    let owner: ContractAddress = starknet::get_contract_address();
    let chain_id: felt252 = 'SN_SEPOLIA';
    let calldata: Array<felt252> = array![owner.into(), chain_id];
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

// ─── Full Flow: Deposit → Transfer → Withdraw ──────────────────

#[test]
fn test_full_deposit_transfer_withdraw_cycle() {
    let pool_addr = deploy_pool_with_compliance(0.try_into().unwrap());
    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };

    // Step 1: Alice deposits 500
    let alice_sk: felt252 = 0xA11CE;
    let note_a1 = Note { owner: 0xA1, value: 500, asset_id: 0, blinding: 0xB1 };
    let cm_a1 = compute_note_commitment(@note_a1);
    pool.deposit(cm_a1, 500, 0);

    // Step 2: Alice deposits another 300
    let note_a2 = Note { owner: 0xA1, value: 300, asset_id: 0, blinding: 0xB2 };
    let cm_a2 = compute_note_commitment(@note_a2);
    pool.deposit(cm_a2, 300, 0);

    assert!(pool.get_leaf_count() == 2, "should have 2 leaves");
    assert!(pool.get_pool_balance(0) == 800, "pool balance should be 800");

    // Step 3: Transfer 600 to Bob (outputs: 600 to Bob, 200 change to Alice)
    let root = pool.get_root();
    let nul1 = compute_nullifier_v2(alice_sk, cm_a1, 'SN_SEPOLIA', 'STARKPRIVACY');
    let nul2 = compute_nullifier_v2(alice_sk, cm_a2, 'SN_SEPOLIA', 'STARKPRIVACY');
    let bob_note = Note { owner: 0xB0B, value: 600, asset_id: 0, blinding: 0xB3 };
    let change_note = Note { owner: 0xA1, value: 200, asset_id: 0, blinding: 0xB4 };
    let cm_bob = compute_note_commitment(@bob_note);
    let cm_change = compute_note_commitment(@change_note);

    let proof: Array<felt252> = array![1]; // mock proof
    pool.transfer(proof.span(), root, (nul1, nul2), (cm_bob, cm_change));

    assert!(pool.is_nullifier_spent(nul1), "nullifier 1 should be spent");
    assert!(pool.is_nullifier_spent(nul2), "nullifier 2 should be spent");
    assert!(pool.get_leaf_count() == 4, "should have 4 leaves");

    // Step 4: Bob withdraws 400 (keeps 200 in pool)
    let root2 = pool.get_root();
    let bob_sk: felt252 = 0xB0B50;
    let bob_nul = compute_nullifier_v2(bob_sk, cm_bob, 'SN_SEPOLIA', 'STARKPRIVACY');
    // Need a second input — use change note with a different key
    let dummy_nul: felt252 = 0xDEAD_BEEF;
    let recipient: ContractAddress = 0x789.try_into().unwrap();
    let bob_change = Note { owner: 0xB0B, value: 200, asset_id: 0, blinding: 0xB5 };
    let cm_bob_change = compute_note_commitment(@bob_change);

    pool
        .withdraw(
            proof.span(), root2, (bob_nul, dummy_nul), cm_bob_change, recipient, 400, 0,
        );

    assert!(pool.is_nullifier_spent(bob_nul), "bob nullifier should be spent");
    assert!(pool.get_pool_balance(0) == 400, "pool balance should be 800 - 400 = 400");
}

// ─── Nullifier Domain Separation ────────────────────────────────

#[test]
fn test_nullifier_domain_separation_across_chains() {
    let note = Note { owner: 0xDEAD, value: 100, asset_id: 0, blinding: 0xBEEF };
    let cm = compute_note_commitment(@note);
    let sk: felt252 = 0xABCDEF;

    let nul_sepolia = compute_nullifier_v2(sk, cm, 'SN_SEPOLIA', 'STARKPRIVACY');
    let nul_mainnet = compute_nullifier_v2(sk, cm, 'SN_MAIN', 'STARKPRIVACY');
    let nul_madara = compute_nullifier_v2(sk, cm, 'MADARA_L3', 'STARKPRIVACY');

    assert!(nul_sepolia != nul_mainnet, "sepolia and mainnet nullifiers must differ");
    assert!(nul_sepolia != nul_madara, "sepolia and madara nullifiers must differ");
    assert!(nul_mainnet != nul_madara, "mainnet and madara nullifiers must differ");
}

#[test]
fn test_nullifier_app_separation() {
    let note = Note { owner: 0xDEAD, value: 100, asset_id: 0, blinding: 0xBEEF };
    let cm = compute_note_commitment(@note);
    let sk: felt252 = 0xABCDEF;

    let nul_app1 = compute_nullifier_v2(sk, cm, 'SN_SEPOLIA', 'APP_A');
    let nul_app2 = compute_nullifier_v2(sk, cm, 'SN_SEPOLIA', 'APP_B');

    assert!(nul_app1 != nul_app2, "different apps must produce different nullifiers");
}

// ─── Stealth + Pool Integration ─────────────────────────────────

#[test]
fn test_stealth_register_then_pool_deposit() {
    let stealth_addr = deploy_stealth_registry();
    let stealth = IStealthRegistryDispatcher { contract_address: stealth_addr };
    let pool_addr = deploy_pool_with_compliance(0.try_into().unwrap());
    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };

    // Register stealth meta-address
    stealth.register_meta_address(0x5AE0D1, 0xF1E301);

    // Derive stealth commitment (simulated)
    let stealth_note = Note { owner: 0x57EA17, value: 100, asset_id: 0, blinding: 0xBF };
    let cm = compute_note_commitment(@stealth_note);

    // Deposit stealth commitment into pool
    pool.deposit(cm, 100, 0);

    // Publish ephemeral key on registry
    stealth.publish_ephemeral_key(0xE1F01B, array![].span(), cm);

    assert!(pool.get_leaf_count() == 1, "pool should have stealth deposit");
    assert!(stealth.get_ephemeral_count() == 1, "registry should have ephemeral key");

    let (eph, stored_cm) = stealth.get_ephemeral_at(0);
    assert!(eph == 0xE1F01B, "ephemeral key mismatch");
    assert!(stored_cm == cm, "commitment on registry should match pool deposit");
}

// ─── Epoch + Bridge Integration ─────────────────────────────────

#[test]
fn test_epoch_nullifier_sync_flow() {
    let epoch_addr = deploy_epoch_manager();
    let epoch = IEpochManagerDispatcher { contract_address: epoch_addr };

    // Simulate: privacy pool records nullifiers during epoch 1 (initial)
    let nul1: felt252 = 0xAF001;
    let nul2: felt252 = 0xAF002;
    let nul3: felt252 = 0xAF003;

    epoch.record_nullifier(nul1);
    epoch.record_nullifier(nul2);
    epoch.record_nullifier(nul3);

    // Finalize epoch 1 -> advance to epoch 2
    epoch.advance_epoch();
    let root_1 = epoch.get_epoch_root(1);

    // Epoch 2: new nullifiers
    epoch.record_nullifier(0xAF004);
    epoch.advance_epoch();
    let root_2 = epoch.get_epoch_root(2);

    // Verification: roots are unique per epoch
    assert!(root_1 != root_2, "epoch roots must be unique");
    assert!(root_1 != 0, "epoch 1 root must be nonzero");
    assert!(root_2 != 0, "epoch 2 root must be nonzero");

    // Cross-chain: a remote chain can verify a nullifier was included
    assert!(epoch.is_nullifier_in_epoch(1, nul1), "nul1 should be in epoch 1");
    assert!(epoch.is_nullifier_in_epoch(1, nul2), "nul2 should be in epoch 1");
    assert!(!epoch.is_nullifier_in_epoch(2, nul1), "nul1 should NOT be in epoch 2");
}

// ─── Multi-Asset Support ────────────────────────────────────────

#[test]
fn test_multi_asset_deposits() {
    let pool_addr = deploy_pool_with_compliance(0.try_into().unwrap());
    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };

    // Deposit ETH (asset 0)
    pool.deposit(0xCA0E01, 1000, 0);
    // Deposit USDC (asset 1)
    pool.deposit(0xCA0E02, 500, 1);
    // Deposit STRK (asset 2)
    pool.deposit(0xCA0E03, 200, 2);

    assert!(pool.get_pool_balance(0) == 1000, "ETH balance should be 1000");
    assert!(pool.get_pool_balance(1) == 500, "USDC balance should be 500");
    assert!(pool.get_pool_balance(2) == 200, "STRK balance should be 200");
    assert!(pool.get_leaf_count() == 3, "should have 3 leaves");
}

#[test]
fn test_multi_asset_withdraw() {
    let pool_addr = deploy_pool_with_compliance(0.try_into().unwrap());
    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };

    pool.deposit(0xCA01, 1000, 0); // ETH
    pool.deposit(0xCA02, 500, 1); // USDC
    pool.deposit(0xCA03, 100, 0); // more ETH

    let root = pool.get_root();
    let recipient: ContractAddress = 0x789.try_into().unwrap();
    let proof: Array<felt252> = array![1];

    // Withdraw 700 ETH
    pool.withdraw(proof.span(), root, (0xAF1, 0xAF2), 0xC1A0E, recipient, 700, 0);

    assert!(pool.get_pool_balance(0) == 400, "ETH balance = 1100 - 700 = 400");
    assert!(pool.get_pool_balance(1) == 500, "USDC balance unchanged");
}
