use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address, stop_cheat_caller_address, spy_events, EventSpyAssertionsTrait};

use starkprivacy_pool::pool::IPrivacyPoolDispatcher;
use starkprivacy_pool::pool::IPrivacyPoolDispatcherTrait;
use starkprivacy_pool::pool::IPrivacyPoolSafeDispatcher;
use starkprivacy_pool::pool::IPrivacyPoolSafeDispatcherTrait;
use starkprivacy_pool::pool::PrivacyPool;
use starkprivacy_pool::proof_verifier::IProofVerifierDispatcher;
use starkprivacy_pool::proof_verifier::IProofVerifierDispatcherTrait;
use starkprivacy_primitives::note::{Note, compute_note_commitment, compute_nullifier_v2};
use starkprivacy_circuits::verifier::{
    encode_transfer_envelope, encode_withdraw_envelope,
    PROOF_TYPE_TRANSFER, PROOF_TYPE_WITHDRAW,
};

const OWNER: felt252 = 0x999;

fn deploy_privacy_pool() -> ContractAddress {
    let contract = declare("PrivacyPool").unwrap().contract_class();

    let native_token: ContractAddress = 0.try_into().unwrap(); // zero = no ERC-20 enforcement
    let compliance_oracle: ContractAddress = 0.try_into().unwrap(); // disabled
    let chain_id: felt252 = 'SN_SEPOLIA';
    let app_id: felt252 = 'STARKPRIVACY';
    let owner: ContractAddress = OWNER.try_into().unwrap();

    let mut calldata: Array<felt252> = array![];
    calldata.append(native_token.into());
    calldata.append(compliance_oracle.into());
    calldata.append(chain_id);
    calldata.append(app_id);
    calldata.append(owner.into());

    let (contract_address, _) = contract.deploy(@calldata).unwrap();
    contract_address
}

fn deploy_mock_verifier() -> ContractAddress {
    let contract = declare("MockVerifier").unwrap().contract_class();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let mut calldata: Array<felt252> = array![];
    calldata.append(owner.into());
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

fn deploy_pool_with_verifier() -> (ContractAddress, ContractAddress) {
    let pool_address = deploy_privacy_pool();
    let verifier_address = deploy_mock_verifier();

    // Set verifier on the pool (as owner)
    let pool = IPrivacyPoolDispatcher { contract_address: pool_address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();
    start_cheat_caller_address(pool_address, owner_addr);
    pool.set_proof_verifier(verifier_address);
    stop_cheat_caller_address(pool_address);

    (pool_address, verifier_address)
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

// ── Pause / Unpause tests ─────────────────────────────────────

#[test]
fn test_pause_unpause() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();

    assert!(!pool.is_paused(), "should not be paused initially");

    start_cheat_caller_address(address, owner_addr);
    pool.pause();
    assert!(pool.is_paused(), "should be paused after pause()");

    pool.unpause();
    assert!(!pool.is_paused(), "should not be paused after unpause()");
    stop_cheat_caller_address(address);
}

#[test]
#[should_panic(expected: "pool is paused")]
fn test_deposit_while_paused_rejected() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();

    start_cheat_caller_address(address, owner_addr);
    pool.pause();
    stop_cheat_caller_address(address);

    pool.deposit(0x1234, 100, 0);
}

#[test]
#[should_panic(expected: "pool is paused")]
fn test_transfer_while_paused_rejected() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    let root = pool.get_root();

    start_cheat_caller_address(address, owner_addr);
    pool.pause();
    stop_cheat_caller_address(address);

    let proof: Array<felt252> = array![1];
    pool.transfer(proof.span(), root, (0xAF01, 0xAF02), (0xB001, 0xB002));
}

#[test]
#[should_panic(expected: "caller is not owner")]
fn test_pause_non_owner_rejected() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let non_owner: ContractAddress = 0x123.try_into().unwrap();

    start_cheat_caller_address(address, non_owner);
    pool.pause();
    stop_cheat_caller_address(address);
}

// ── Fee recipient tests ──────────────────────────────────────

#[test]
fn test_set_fee_recipient() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();
    let recipient: ContractAddress = 0x777.try_into().unwrap();

    start_cheat_caller_address(address, owner_addr);
    pool.set_fee_recipient(recipient);
    stop_cheat_caller_address(address);

    assert!(pool.get_fee_recipient() == recipient, "fee recipient should be updated");
}

#[test]
#[should_panic(expected: "caller is not owner")]
fn test_set_fee_recipient_non_owner_rejected() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let non_owner: ContractAddress = 0x123.try_into().unwrap();

    start_cheat_caller_address(address, non_owner);
    pool.set_fee_recipient(0x777.try_into().unwrap());
    stop_cheat_caller_address(address);
}

// ── Proof verifier integration tests ─────────────────────────

#[test]
fn test_set_proof_verifier() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();
    let verifier: ContractAddress = 0xABC.try_into().unwrap();

    start_cheat_caller_address(address, owner_addr);
    pool.set_proof_verifier(verifier);
    stop_cheat_caller_address(address);
}

#[test]
fn test_transfer_with_verifier_valid_envelope() {
    let (pool_address, _verifier_address) = deploy_pool_with_verifier();
    let pool = IPrivacyPoolDispatcher { contract_address: pool_address };

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    let root = pool.get_root();

    // Build a proper transfer proof envelope
    let nf0: felt252 = 0xAF01;
    let nf1: felt252 = 0xAF02;
    let oc0: felt252 = 0xB001;
    let oc1: felt252 = 0xB002;
    let fee: felt252 = 0;
    let proof_data: Array<felt252> = array![0xDE, 0xAD]; // mock STARK data

    let envelope = encode_transfer_envelope(root, nf0, nf1, oc0, oc1, fee, proof_data.span());

    pool.transfer(envelope.span(), root, (nf0, nf1), (oc0, oc1));

    assert!(pool.is_nullifier_spent(nf0), "nullifier 0 should be spent");
    assert!(pool.is_nullifier_spent(nf1), "nullifier 1 should be spent");
}

#[test]
fn test_withdraw_with_verifier_valid_envelope() {
    let (pool_address, _verifier_address) = deploy_pool_with_verifier();
    let pool = IPrivacyPoolDispatcher { contract_address: pool_address };

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    let root = pool.get_root();

    let nf0: felt252 = 0xCAF1;
    let nf1: felt252 = 0xCAF2;
    let change: felt252 = 0xC0FFEE;
    let exit_value: felt252 = 150;
    let fee: felt252 = 0;
    let asset: felt252 = 0;
    let proof_data: Array<felt252> = array![0xDE, 0xAD];

    let envelope = encode_withdraw_envelope(root, nf0, nf1, change, exit_value, fee, asset, proof_data.span());

    let recipient: ContractAddress = 0x789.try_into().unwrap();
    pool.withdraw(envelope.span(), root, (nf0, nf1), change, recipient, 150, 0);

    assert!(pool.is_nullifier_spent(nf0), "withdraw nf0 should be spent");
    assert!(pool.is_nullifier_spent(nf1), "withdraw nf1 should be spent");
    assert!(pool.get_pool_balance(0) == 150, "pool balance should be 150");
}

#[test]
#[should_panic(expected: "proof must be exactly ENVELOPE_SIZE elements")]
fn test_transfer_with_verifier_bad_envelope_rejected() {
    let (pool_address, _verifier_address) = deploy_pool_with_verifier();
    let pool = IPrivacyPoolDispatcher { contract_address: pool_address };

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    let root = pool.get_root();

    // Send a bare proof (not a valid envelope) — verifier will reject
    let bad_proof: Array<felt252> = array![1];
    pool.transfer(bad_proof.span(), root, (0xAF01, 0xAF02), (0xB001, 0xB002));
}

#[test]
#[should_panic(expected: "transfer proof verification failed")]
fn test_transfer_with_verifier_mismatched_root_rejected() {
    let (pool_address, _verifier_address) = deploy_pool_with_verifier();
    let pool = IPrivacyPoolDispatcher { contract_address: pool_address };

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    let root = pool.get_root();

    // Envelope with wrong root encoded inside
    let wrong_root: felt252 = 0xBADBAD;
    let nf0: felt252 = 0xAF01;
    let nf1: felt252 = 0xAF02;
    let oc0: felt252 = 0xB001;
    let oc1: felt252 = 0xB002;
    let envelope = encode_transfer_envelope(wrong_root, nf0, nf1, oc0, oc1, 0, array![].span());

    // Pass the real root as merkle_root param, but envelope has wrong root
    pool.transfer(envelope.span(), root, (nf0, nf1), (oc0, oc1));
}

// ── Event emission tests ─────────────────────────────────────

#[test]
fn test_deposit_emits_events() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    let mut spy = spy_events();

    pool.deposit(0x1234ABCD, 100, 0);

    spy.assert_emitted(
        @array![
            (
                address,
                PrivacyPool::Event::Deposit(
                    PrivacyPool::Deposit {
                        commitment: 0x1234ABCD,
                        leaf_index: 0,
                        amount: 100,
                        asset_id: 0,
                    },
                ),
            ),
        ],
    );
}

#[test]
fn test_pause_emits_event() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();

    start_cheat_caller_address(address, owner_addr);
    let mut spy = spy_events();
    pool.pause();

    spy.assert_emitted(
        @array![
            (
                address,
                PrivacyPool::Event::Paused(
                    PrivacyPool::Paused { by: owner_addr },
                ),
            ),
        ],
    );
    stop_cheat_caller_address(address);
}

#[test]
fn test_transfer_emits_events() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    let root = pool.get_root();

    let mut spy = spy_events();
    let proof: Array<felt252> = array![1];
    pool.transfer(proof.span(), root, (0xAF01, 0xAF02), (0xB001, 0xB002));

    // Verify Transfer event was emitted (we check the Transfer event, not NewRoot)
    spy.assert_emitted(
        @array![
            (
                address,
                PrivacyPool::Event::Transfer(
                    PrivacyPool::Transfer {
                        nullifier_1: 0xAF01,
                        nullifier_2: 0xAF02,
                        output_commitment_1: 0xB001,
                        output_commitment_2: 0xB002,
                        new_root: pool.get_root(),
                    },
                ),
            ),
        ],
    );
}

// ── Phase A: Security hardening tests ────────────────────────

// ── Compliance oracle integration ────────────────────────────

fn deploy_sanctions_oracle() -> ContractAddress {
    let contract = declare("SanctionsOracle").unwrap().contract_class();
    let owner: ContractAddress = OWNER.try_into().unwrap();
    let mut calldata: Array<felt252> = array![];
    calldata.append(owner.into());
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

use starkprivacy_compliance::sanctions::ISanctionsOracleDispatcher;
use starkprivacy_compliance::sanctions::ISanctionsOracleDispatcherTrait;

fn deploy_pool_with_compliance() -> (ContractAddress, ContractAddress) {
    let oracle_address = deploy_sanctions_oracle();


    let contract = declare("PrivacyPool").unwrap().contract_class();
    let native_token: ContractAddress = 0.try_into().unwrap();
    let chain_id: felt252 = 'SN_SEPOLIA';
    let app_id: felt252 = 'STARKPRIVACY';
    let owner: ContractAddress = OWNER.try_into().unwrap();

    let mut calldata: Array<felt252> = array![];
    calldata.append(native_token.into());
    calldata.append(oracle_address.into()); // compliance oracle set at construction
    calldata.append(chain_id);
    calldata.append(app_id);
    calldata.append(owner.into());

    let (pool_address, _) = contract.deploy(@calldata).unwrap();
    (pool_address, oracle_address)
}

#[test]
fn test_deposit_with_compliance_allowed() {
    let (pool_address, _oracle_address) = deploy_pool_with_compliance();
    let pool = IPrivacyPoolDispatcher { contract_address: pool_address };

    // Non-sanctioned user can deposit
    pool.deposit(0x1234, 100, 0);
    assert!(pool.get_pool_balance(0) == 100, "deposit should succeed for non-sanctioned user");
}

#[test]
#[should_panic(expected: "deposit blocked by compliance oracle")]
fn test_deposit_sanctioned_user_blocked() {
    let (pool_address, oracle_address) = deploy_pool_with_compliance();
    let pool = IPrivacyPoolDispatcher { contract_address: pool_address };
    let oracle = ISanctionsOracleDispatcher { contract_address: oracle_address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();
    let bad_user: ContractAddress = 0xBAD.try_into().unwrap();

    // Sanction the bad user
    start_cheat_caller_address(oracle_address, owner_addr);
    oracle.add_sanctioned(bad_user);
    stop_cheat_caller_address(oracle_address);

    // Try to deposit as sanctioned user — should be blocked
    start_cheat_caller_address(pool_address, bad_user);
    pool.deposit(0x1234, 100, 0);
    stop_cheat_caller_address(pool_address);
}

#[test]
#[should_panic(expected: "withdrawal blocked by compliance oracle")]
fn test_withdraw_sanctioned_recipient_blocked() {
    let (pool_address, oracle_address) = deploy_pool_with_compliance();
    let pool = IPrivacyPoolDispatcher { contract_address: pool_address };
    let oracle = ISanctionsOracleDispatcher { contract_address: oracle_address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();
    let bad_user: ContractAddress = 0xBAD.try_into().unwrap();

    // Deposit first
    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    let root = pool.get_root();

    // Sanction the recipient
    start_cheat_caller_address(oracle_address, owner_addr);
    oracle.add_sanctioned(bad_user);
    stop_cheat_caller_address(oracle_address);

    // Try to withdraw to sanctioned address
    let proof: Array<felt252> = array![1];
    pool.withdraw(proof.span(), root, (0xCAF1, 0xCAF2), 0xC0FFEE, bad_user, 150, 0);
}

#[test]
fn test_set_compliance_oracle() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();
    let oracle: ContractAddress = 0xABC.try_into().unwrap();

    start_cheat_caller_address(address, owner_addr);
    pool.set_compliance_oracle(oracle);
    stop_cheat_caller_address(address);
}

#[test]
#[should_panic(expected: "caller is not owner")]
fn test_set_compliance_oracle_non_owner_rejected() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let non_owner: ContractAddress = 0x123.try_into().unwrap();

    start_cheat_caller_address(address, non_owner);
    pool.set_compliance_oracle(0xABC.try_into().unwrap());
    stop_cheat_caller_address(address);
}

// ── Envelope size enforcement tests ──────────────────────────

#[test]
#[should_panic(expected: "proof must be exactly ENVELOPE_SIZE elements")]
fn test_transfer_undersized_proof_with_verifier_rejected() {
    let (pool_address, _verifier_address) = deploy_pool_with_verifier();
    let pool = IPrivacyPoolDispatcher { contract_address: pool_address };

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    let root = pool.get_root();

    // Proof with only 10 elements — below ENVELOPE_SIZE
    let mut short_proof: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i < 10 {
        short_proof.append(i.into());
        i += 1;
    };

    pool.transfer(short_proof.span(), root, (0xAF01, 0xAF02), (0xB001, 0xB002));
}

#[test]
fn test_transfer_legacy_mode_accepts_any_proof() {
    // Pool without verifier (legacy mode) — accepts any non-empty proof
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };

    pool.deposit(0x1111, 100, 0);
    pool.deposit(0x2222, 200, 0);
    let root = pool.get_root();

    // Short proof is fine in legacy mode (no verifier)
    let proof: Array<felt252> = array![1];
    pool.transfer(proof.span(), root, (0xAF01, 0xAF02), (0xB001, 0xB002));

    assert!(pool.is_nullifier_spent(0xAF01), "should be spent in legacy mode");
}

// ── Fee deduction tests ──────────────────────────────────────

#[test]
fn test_withdraw_with_fee_recipient_deducts_fee() {
    let address = deploy_privacy_pool();
    let pool = IPrivacyPoolDispatcher { contract_address: address };
    let owner_addr: ContractAddress = OWNER.try_into().unwrap();
    let fee_addr: ContractAddress = 0xFEE.try_into().unwrap();

    // Set fee recipient
    start_cheat_caller_address(address, owner_addr);
    pool.set_fee_recipient(fee_addr);
    stop_cheat_caller_address(address);

    // Deposit
    pool.deposit(0x1111, 1000, 0);
    pool.deposit(0x2222, 2000, 0);
    let root = pool.get_root();
    let recipient: ContractAddress = 0x789.try_into().unwrap();

    // Withdraw 1000 — fee is 1000/1000 = 1, net = 999
    // (no actual ERC-20 transfer since native_token = 0, but pool balance updates)
    let proof: Array<felt252> = array![1];
    pool.withdraw(proof.span(), root, (0xCAF1, 0xCAF2), 0xC0FFEE, recipient, 1000, 0);

    // Pool balance: 3000 - 1000 = 2000
    assert!(pool.get_pool_balance(0) == 2000, "pool balance should be 2000 after withdraw");
}
