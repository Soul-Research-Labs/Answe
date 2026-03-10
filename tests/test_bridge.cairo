use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

use starkprivacy_bridge::epoch_manager::IEpochManagerDispatcher;
use starkprivacy_bridge::epoch_manager::IEpochManagerDispatcherTrait;
use starkprivacy_bridge::router::IBridgeRouterDispatcher;
use starkprivacy_bridge::router::IBridgeRouterDispatcherTrait;

fn deploy_epoch_manager() -> ContractAddress {
    let contract = declare("EpochManager").unwrap().contract_class();
    let owner: ContractAddress = starknet::get_contract_address();
    let chain_id: felt252 = 'SN_SEPOLIA';
    let calldata: Array<felt252> = array![owner.into(), chain_id];
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

fn deploy_bridge_router(pool: ContractAddress) -> ContractAddress {
    let contract = declare("BridgeRouter").unwrap().contract_class();
    let owner: ContractAddress = starknet::get_contract_address();
    let chain_id: felt252 = 'SN_SEPOLIA';
    let calldata: Array<felt252> = array![pool.into(), owner.into(), chain_id];
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

// ─── EpochManager Tests ─────────────────────────────────────────

#[test]
fn test_epoch_initial_state() {
    let address = deploy_epoch_manager();
    let mgr = IEpochManagerDispatcher { contract_address: address };

    assert!(mgr.get_current_epoch() == 1, "initial epoch should be 1");
    assert!(mgr.get_current_epoch_count() == 0, "initial count should be 0");
    assert!(mgr.get_chain_id() == 'SN_SEPOLIA', "chain_id mismatch");
}

#[test]
fn test_epoch_record_nullifier() {
    let address = deploy_epoch_manager();
    let mgr = IEpochManagerDispatcher { contract_address: address };

    mgr.record_nullifier(0xAF01);
    assert!(mgr.get_current_epoch_count() == 1, "count should be 1 after recording");
    assert!(mgr.is_nullifier_in_epoch(1, 0xAF01), "nullifier should be in epoch 1");
}

#[test]
fn test_epoch_record_multiple_nullifiers() {
    let address = deploy_epoch_manager();
    let mgr = IEpochManagerDispatcher { contract_address: address };

    mgr.record_nullifier(0xA01);
    mgr.record_nullifier(0xA02);
    mgr.record_nullifier(0xA03);

    assert!(mgr.get_current_epoch_count() == 3, "count should be 3");
    assert!(mgr.is_nullifier_in_epoch(1, 0xA01), "nullifier A01 in epoch 1");
    assert!(mgr.is_nullifier_in_epoch(1, 0xA02), "nullifier A02 in epoch 1");
    assert!(mgr.is_nullifier_in_epoch(1, 0xA03), "nullifier A03 in epoch 1");
}

#[test]
fn test_epoch_advance() {
    let address = deploy_epoch_manager();
    let mgr = IEpochManagerDispatcher { contract_address: address };

    // Record some nullifiers in epoch 1 (initial)
    mgr.record_nullifier(0xA01);
    mgr.record_nullifier(0xA02);

    // Advance to epoch 2
    mgr.advance_epoch();

    assert!(mgr.get_current_epoch() == 2, "should be in epoch 2");
    assert!(mgr.get_current_epoch_count() == 0, "new epoch should have 0 nullifiers");

    // Epoch 1 should have a finalized root
    let root = mgr.get_epoch_root(1);
    assert!(root != 0, "finalized epoch root should be nonzero");
}

#[test]
fn test_epoch_advance_multiple() {
    let address = deploy_epoch_manager();
    let mgr = IEpochManagerDispatcher { contract_address: address };

    // Epoch 1 (initial)
    mgr.record_nullifier(0x001);
    mgr.advance_epoch(); // -> epoch 2

    mgr.record_nullifier(0x010);
    mgr.record_nullifier(0x011);
    mgr.advance_epoch(); // -> epoch 3

    mgr.record_nullifier(0x100);
    mgr.advance_epoch(); // -> epoch 4

    assert!(mgr.get_current_epoch() == 4, "should be in epoch 4");

    // Each finalized epoch should have a distinct root
    let r1 = mgr.get_epoch_root(1);
    let r2 = mgr.get_epoch_root(2);
    let r3 = mgr.get_epoch_root(3);

    assert!(r1 != 0, "epoch 1 root nonzero");
    assert!(r2 != 0, "epoch 2 root nonzero");
    assert!(r3 != 0, "epoch 3 root nonzero");
    assert!(r1 != r2, "epoch 1 and 2 roots should differ");
    assert!(r2 != r3, "epoch 2 and 3 roots should differ");
}

#[test]
fn test_epoch_nullifier_not_in_wrong_epoch() {
    let address = deploy_epoch_manager();
    let mgr = IEpochManagerDispatcher { contract_address: address };

    // Epoch 1 (initial)
    mgr.record_nullifier(0xA01);
    mgr.advance_epoch(); // -> epoch 2
    mgr.record_nullifier(0xB01);

    assert!(mgr.is_nullifier_in_epoch(1, 0xA01), "A01 should be in epoch 1");
    assert!(!mgr.is_nullifier_in_epoch(2, 0xA01), "A01 should NOT be in epoch 2");
    assert!(mgr.is_nullifier_in_epoch(2, 0xB01), "B01 should be in epoch 2");
    assert!(!mgr.is_nullifier_in_epoch(1, 0xB01), "B01 should NOT be in epoch 1");
}

// ─── BridgeRouter Tests ─────────────────────────────────────────

#[test]
fn test_bridge_initial_state() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let address = deploy_bridge_router(pool);
    let bridge = IBridgeRouterDispatcher { contract_address: address };

    assert!(bridge.get_pool() == pool, "pool address mismatch");
    assert!(bridge.get_current_epoch() == 0, "initial epoch should be 0");
}

#[test]
fn test_bridge_publish_epoch_root() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let address = deploy_bridge_router(pool);
    let bridge = IBridgeRouterDispatcher { contract_address: address };

    let epoch: u64 = 1; // must be current_epoch + 1 = 0 + 1 = 1
    let root: felt252 = 0xA00FBA5E;

    bridge.publish_epoch_root(epoch, root);
    assert!(bridge.get_epoch_root(epoch) == root, "epoch root mismatch");
}

#[test]
fn test_bridge_lock_for_bridge() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let address = deploy_bridge_router(pool);
    let bridge = IBridgeRouterDispatcher { contract_address: address };

    let commitment: felt252 = 0xC0AA11;
    let dest_chain: felt252 = 'ETHEREUM';
    let proof: Array<felt252> = array![1];
    let nullifiers = (0xAF01, 0xAF02);

    bridge.lock_for_bridge(commitment, dest_chain, proof.span(), nullifiers);
    // If no panic, lock succeeded
}

#[test]
fn test_bridge_multiple_epoch_roots() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let address = deploy_bridge_router(pool);
    let bridge = IBridgeRouterDispatcher { contract_address: address };

    // Must publish sequentially: 1, 2, 3 (current_epoch starts at 0)
    bridge.publish_epoch_root(1, 0xA00F1);
    bridge.publish_epoch_root(2, 0xA00F2);
    bridge.publish_epoch_root(3, 0xA00F3);

    assert!(bridge.get_epoch_root(1) == 0xA00F1, "epoch 1 root mismatch");
    assert!(bridge.get_epoch_root(2) == 0xA00F2, "epoch 2 root mismatch");
    assert!(bridge.get_epoch_root(3) == 0xA00F3, "epoch 3 root mismatch");
}
