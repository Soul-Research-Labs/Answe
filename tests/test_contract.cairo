use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

use starkprivacy_pool::pool::IPrivacyPoolDispatcher;
use starkprivacy_pool::pool::IPrivacyPoolDispatcherTrait;
use starkprivacy_pool::pool::IPrivacyPoolSafeDispatcher;
use starkprivacy_pool::pool::IPrivacyPoolSafeDispatcherTrait;
use starkprivacy_primitives::note::{Note, compute_note_commitment, compute_nullifier_v2};

fn deploy_privacy_pool() -> ContractAddress {
    let contract = declare("PrivacyPool").unwrap().contract_class();

    let native_token: ContractAddress = 0x1.try_into().unwrap();
    let compliance_oracle: ContractAddress = 0.try_into().unwrap(); // disabled
    let chain_id: felt252 = 'SN_SEPOLIA';
    let app_id: felt252 = 'STARKPRIVACY';
    let owner: ContractAddress = 0x999.try_into().unwrap();

    let mut calldata: Array<felt252> = array![];
    calldata.append(native_token.into());
    calldata.append(compliance_oracle.into());
    calldata.append(chain_id);
    calldata.append(app_id);
    calldata.append(owner.into());

    let (contract_address, _) = contract.deploy(@calldata).unwrap();
    contract_address
}

#[test]
fn test_initial_state() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    assert!(pool.get_leaf_count() == 0, "initial leaf count should be 0");
    assert!(pool.get_root() != 0, "initial root should be nonzero (empty tree root)");
    assert!(pool.get_pool_balance(0) == 0, "initial balance should be 0");
}

#[test]
fn test_deposit() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    let commitment: felt252 = 0x1234ABCD;
    pool.deposit(commitment, 100, 0);

    assert!(pool.get_leaf_count() == 1, "leaf count should be 1 after deposit");
    assert!(pool.get_pool_balance(0) == 100, "pool balance should be 100");
}

#[test]
fn test_deposit_changes_root() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    let root_before = pool.get_root();
    pool.deposit(0xAAAA, 50, 0);
    let root_after = pool.get_root();

    assert!(root_before != root_after, "root must change after deposit");
}

#[test]
fn test_multiple_deposits() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    pool.deposit(0x3333, 300, 0);

    assert!(pool.get_leaf_count() == 3, "leaf count should be 3");
    assert!(pool.get_pool_balance(0) == 600, "pool balance should be 600");
}

#[test]
fn test_known_root_after_deposit() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    pool.deposit(0xAAAA, 50, 0);
    let current_root = pool.get_root();

    assert!(pool.is_known_root(current_root), "current root should be known");
}

#[test]
fn test_transfer() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    // Deposit first
    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);

    let root = pool.get_root();

    // Transfer (with mock proof)
    let proof: Array<felt252> = array![1]; // mock proof
    let nullifiers = (0xAF01, 0xAF02);
    let outputs = (0xB001, 0xB002);

    pool.transfer(proof.span(), root, nullifiers, outputs);

    // Nullifiers should be spent
    assert!(pool.is_nullifier_spent(0xAF01), "nullifier 1 should be spent");
    assert!(pool.is_nullifier_spent(0xAF02), "nullifier 2 should be spent");

    // Two new leaves added (outputs)
    assert!(pool.get_leaf_count() == 4, "leaf count should be 4 (2 deposits + 2 outputs)");
}

#[test]
fn test_withdraw() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    // Deposit
    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);

    let root = pool.get_root();
    let recipient: ContractAddress = 0x789.try_into().unwrap();
    let proof: Array<felt252> = array![1];

    pool
        .withdraw(
            proof.span(),
            root,
            (0xCAF1, 0xCAF2),
            0xC0FFEE, // change commitment
            recipient,
            150,
            0,
        );

    assert!(pool.is_nullifier_spent(0xCAF1), "withdraw nullifier 1 should be spent");
    assert!(pool.is_nullifier_spent(0xCAF2), "withdraw nullifier 2 should be spent");
    assert!(pool.get_pool_balance(0) == 150, "pool balance should be 300 - 150 = 150");
}

#[test]
#[should_panic(expected: "nullifier 1 already spent")]
fn test_double_spend_rejected() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);

    let root = pool.get_root();
    let proof: Array<felt252> = array![1];

    // First transfer
    pool.transfer(proof.span(), root, (0xAF01, 0xAF02), (0xB001, 0xB002));

    // Second transfer reusing nullifier — should panic
    let root2 = pool.get_root();
    pool.transfer(proof.span(), root2, (0xAF01, 0xAF03), (0xB003, 0xB004));
}

#[test]
#[should_panic(expected: "commitment cannot be zero")]
fn test_deposit_zero_commitment_rejected() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    pool.deposit(0, 100, 0);
}

#[test]
#[should_panic(expected: "amount must be positive")]
fn test_deposit_zero_amount_rejected() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    pool.deposit(0x1234, 0, 0);
}

#[test]
fn test_note_commitment_integration() {
    // Test that primitives integrate correctly for pool usage
    let note = Note { owner: 0xDEAD, value: 100, asset_id: 0, blinding: 0xBEEF };
    let commitment = compute_note_commitment(@note);
    assert!(commitment != 0, "commitment should be nonzero");

    let nullifier = compute_nullifier_v2(0xABCD, commitment, 'SN_SEPOLIA', 'STARKPRIVACY');
    assert!(nullifier != 0, "nullifier should be nonzero");
    assert!(nullifier != commitment, "nullifier and commitment should differ");
}
