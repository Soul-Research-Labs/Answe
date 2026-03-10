use snforge_std::{declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address};
use starknet::ContractAddress;
use starkprivacy_bridge::madara_adapter::{IMadaraAdapterDispatcher, IMadaraAdapterDispatcherTrait};

const CHAIN_A: felt252 = 'MADARA_A';
const CHAIN_B: felt252 = 'MADARA_B';

fn deploy_madara_adapter(
    chain_id: felt252,
    pool: ContractAddress,
    epoch_mgr: ContractAddress,
) -> ContractAddress {
    let contract = declare("MadaraAdapter").unwrap().contract_class();
    let owner: ContractAddress = starknet::contract_address_const::<0x1>();
    let (address, _) = contract.deploy(
        @array![owner.into(), chain_id, pool.into(), epoch_mgr.into()]
    ).unwrap();

    // Cheat caller to owner for subsequent calls
    start_cheat_caller_address(address, owner);
    address
}

// ─── Registration ────────────────────────────────────────────────

#[test]
fn test_madara_initial_state() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    assert!(adapter.get_chain_id() == CHAIN_A, "chain_id mismatch");
    assert!(!adapter.is_peer_registered(CHAIN_B), "B should not be registered yet");
    assert!(adapter.get_outbound_count(CHAIN_B) == 0, "outbound should be 0");
    assert!(adapter.get_inbound_count(CHAIN_B) == 0, "inbound should be 0");
}

#[test]
fn test_register_peer() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    let peer_adapter: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_B, peer_adapter);

    assert!(adapter.is_peer_registered(CHAIN_B), "B should be registered");
}

#[test]
#[should_panic(expected: "cannot peer with self")]
fn test_register_self_rejected() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    let peer: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_A, peer); // Same as self chain_id
}

#[test]
#[should_panic(expected: "peer already registered")]
fn test_register_duplicate_rejected() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    let peer: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_B, peer);
    adapter.register_peer(CHAIN_B, peer); // Duplicate
}

// ─── Cross-chain lock ────────────────────────────────────────────

#[test]
fn test_lock_for_appchain() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    // Register peer first
    let peer: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_B, peer);

    // Lock for bridge
    adapter.lock_for_appchain(0xCAFE, CHAIN_B, (0x111, 0x222), 0xABC);

    assert!(adapter.get_outbound_count(CHAIN_B) == 1, "outbound should be 1");
}

#[test]
#[should_panic(expected: "unknown peer chain")]
fn test_lock_unknown_peer_rejected() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    // No peer registered — should fail
    adapter.lock_for_appchain(0xCAFE, CHAIN_B, (0x111, 0x222), 0xABC);
}

#[test]
#[should_panic(expected: "duplicate nullifiers")]
fn test_lock_duplicate_nullifiers_rejected() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    let peer: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_B, peer);
    adapter.lock_for_appchain(0xCAFE, CHAIN_B, (0x111, 0x111), 0xABC);
}

#[test]
#[should_panic(expected: "commitment already processed")]
fn test_lock_same_commitment_twice_rejected() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    let peer: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_B, peer);

    adapter.lock_for_appchain(0xCAFE, CHAIN_B, (0x111, 0x222), 0xABC);
    adapter.lock_for_appchain(0xCAFE, CHAIN_B, (0x333, 0x444), 0xDEF); // Same commitment
}

// ─── Epoch root sync + receive ───────────────────────────────────

#[test]
fn test_sync_epoch_root() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    let peer: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_B, peer);

    adapter.sync_epoch_root(CHAIN_B, 1, 0xBEEF);
    assert!(adapter.get_peer_epoch_root(CHAIN_B, 1) == 0xBEEF, "synced root mismatch");
}

#[test]
fn test_receive_from_appchain() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    let peer: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_B, peer);

    // Sync epoch root first
    adapter.sync_epoch_root(CHAIN_B, 1, 0xBEEF);

    // Receive from appchain
    adapter.receive_from_appchain(0xCAFE, CHAIN_B, 1, 0xBEEF, 0xABC);
    assert!(adapter.get_inbound_count(CHAIN_B) == 1, "inbound should be 1");
}

#[test]
#[should_panic(expected: "epoch root not synced")]
fn test_receive_without_synced_root_rejected() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    let peer: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_B, peer);

    // No epoch root synced — should fail
    adapter.receive_from_appchain(0xCAFE, CHAIN_B, 1, 0xBEEF, 0xABC);
}

#[test]
#[should_panic(expected: "epoch root mismatch")]
fn test_receive_wrong_epoch_root_rejected() {
    let pool: ContractAddress = 0x999.try_into().unwrap();
    let epoch: ContractAddress = 0x888.try_into().unwrap();
    let address = deploy_madara_adapter(CHAIN_A, pool, epoch);
    let adapter = IMadaraAdapterDispatcher { contract_address: address };

    let peer: ContractAddress = 0x777.try_into().unwrap();
    adapter.register_peer(CHAIN_B, peer);

    adapter.sync_epoch_root(CHAIN_B, 1, 0xBEEF);
    // Wrong epoch root — should fail
    adapter.receive_from_appchain(0xCAFE, CHAIN_B, 1, 0xDEAD, 0xABC);
}

// ─── Full cross-appchain flow ────────────────────────────────────

#[test]
fn test_full_cross_appchain_flow() {
    let pool_a: ContractAddress = 0xA01.try_into().unwrap();
    let pool_b: ContractAddress = 0xB01.try_into().unwrap();
    let epoch_a: ContractAddress = 0xA02.try_into().unwrap();
    let epoch_b: ContractAddress = 0xB02.try_into().unwrap();

    let addr_a = deploy_madara_adapter(CHAIN_A, pool_a, epoch_a);
    let addr_b = deploy_madara_adapter(CHAIN_B, pool_b, epoch_b);

    let adapter_a = IMadaraAdapterDispatcher { contract_address: addr_a };
    let adapter_b = IMadaraAdapterDispatcher { contract_address: addr_b };

    // Register peers on both sides
    adapter_a.register_peer(CHAIN_B, addr_b);
    adapter_b.register_peer(CHAIN_A, addr_a);

    // 1. Lock commitment on Chain A for transfer to Chain B
    adapter_a.lock_for_appchain(0xCAFE01, CHAIN_B, (0x111, 0x222), 0xABC);
    assert!(adapter_a.get_outbound_count(CHAIN_B) == 1, "A outbound should be 1");

    // 2. Sync epoch root from Chain A to Chain B
    let epoch_root_a: felt252 = 0xA0A0A0;
    adapter_b.sync_epoch_root(CHAIN_A, 1, epoch_root_a);
    assert!(adapter_b.get_peer_epoch_root(CHAIN_A, 1) == epoch_root_a, "synced root mismatch");

    // 3. Receive the commitment on Chain B
    adapter_b.receive_from_appchain(0xCAFE01, CHAIN_A, 1, epoch_root_a, 0xABC);
    assert!(adapter_b.get_inbound_count(CHAIN_A) == 1, "B inbound should be 1");

    // 4. Now do the reverse: lock on B for A
    adapter_b.lock_for_appchain(0xCAFE02, CHAIN_A, (0x333, 0x444), 0xDEF);
    assert!(adapter_b.get_outbound_count(CHAIN_A) == 1, "B outbound should be 1");

    let epoch_root_b: felt252 = 0xB0B0B0;
    adapter_a.sync_epoch_root(CHAIN_B, 1, epoch_root_b);
    adapter_a.receive_from_appchain(0xCAFE02, CHAIN_B, 1, epoch_root_b, 0xDEF);
    assert!(adapter_a.get_inbound_count(CHAIN_B) == 1, "A inbound should be 1");
}
