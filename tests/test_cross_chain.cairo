use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address};

use starkprivacy_pool::pool::IPrivacyPoolDispatcher;
use starkprivacy_pool::pool::IPrivacyPoolDispatcherTrait;
use starkprivacy_bridge::kakarot_adapter::{IKakarotAdapterDispatcher, IKakarotAdapterDispatcherTrait};
use starkprivacy_bridge::madara_adapter::{IMadaraAdapterDispatcher, IMadaraAdapterDispatcherTrait};
use starkprivacy_bridge::epoch_manager::{IEpochManagerDispatcher, IEpochManagerDispatcherTrait};
use starkprivacy_primitives::note::{Note, compute_note_commitment, compute_nullifier_v2};

const CHAIN_STARKNET: felt252 = 'SN_SEPOLIA';
const CHAIN_MADARA: felt252 = 'MADARA_L3';

fn owner() -> ContractAddress {
    starknet::contract_address_const::<0x1>()
}

fn deploy_pool() -> ContractAddress {
    let contract = declare("PrivacyPool").unwrap().contract_class();
    let native_token: ContractAddress = 0.try_into().unwrap();
    let compliance: ContractAddress = 0.try_into().unwrap();
    let calldata: Array<felt252> = array![
        native_token.into(), compliance.into(), CHAIN_STARKNET, 'STARKPRIVACY', owner().into(),
    ];
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

fn deploy_kakarot_adapter(pool: ContractAddress, gas_factor: u256) -> ContractAddress {
    let contract = declare("KakarotAdapter").unwrap().contract_class();
    let (lo, hi) = (gas_factor & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, gas_factor / 0x100000000000000000000000000000000);
    let calldata: Array<felt252> = array![pool.into(), owner().into(), lo.try_into().unwrap(), hi.try_into().unwrap()];
    let (address, _) = contract.deploy(@calldata).unwrap();
    start_cheat_caller_address(address, owner());
    address
}

fn deploy_epoch_manager() -> ContractAddress {
    let contract = declare("EpochManager").unwrap().contract_class();
    let calldata: Array<felt252> = array![owner().into(), CHAIN_STARKNET];
    let (address, _) = contract.deploy(@calldata).unwrap();
    start_cheat_caller_address(address, owner());
    address
}

fn deploy_madara_adapter(chain_id: felt252, pool: ContractAddress, epoch: ContractAddress) -> ContractAddress {
    let contract = declare("MadaraAdapter").unwrap().contract_class();
    let (address, _) = contract.deploy(@array![owner().into(), chain_id, pool.into(), epoch.into()]).unwrap();
    start_cheat_caller_address(address, owner());
    address
}

// ─── KakarotAdapter + Pool Integration ──────────────────────────

#[test]
fn test_kakarot_deposit_through_pool() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000); // 1x factor
    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    // EVM deposit routes to pool
    kakarot.evm_deposit(0xCAFE01, 500, 0);

    assert!(pool.get_leaf_count() == 1, "pool should have 1 leaf");
    assert!(pool.get_pool_balance(0) == 500, "pool balance should be 500");
}

#[test]
fn test_kakarot_view_proxies_reflect_pool_state() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    // Deposit directly through pool
    pool.deposit(0xABCD, 100, 0);
    pool.deposit(0xEF01, 200, 1);

    // Kakarot views should mirror pool state
    assert!(kakarot.get_leaf_count() == 2, "leaf count via kakarot");
    assert!(kakarot.get_pool_balance(0) == 100, "asset 0 balance via kakarot");
    assert!(kakarot.get_pool_balance(1) == 200, "asset 1 balance via kakarot");
    assert!(kakarot.get_root() == pool.get_root(), "root should match");
}

#[test]
fn test_kakarot_transfer_spends_nullifiers() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    // Two deposits
    pool.deposit(0xA01, 500, 0);
    pool.deposit(0xA02, 300, 0);
    let root = pool.get_root();

    // Transfer via kakarot adapter
    let proof: Array<felt252> = array![1];
    let nullifiers = (0xAF01, 0xAF02);
    let outputs = (0xAC01, 0xAC02);
    kakarot.evm_transfer(proof.span(), root, nullifiers, outputs);

    assert!(kakarot.is_nullifier_spent(0xAF01), "nf1 spent via kakarot");
    assert!(kakarot.is_nullifier_spent(0xAF02), "nf2 spent via kakarot");
    assert!(pool.is_nullifier_spent(0xAF01), "nf1 spent on pool directly");
    assert!(kakarot.get_leaf_count() == 4, "should have 4 leaves after transfer");
}

#[test]
fn test_kakarot_withdraw_updates_balance() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    pool.deposit(0xD01, 1000, 0);
    pool.deposit(0xD02, 500, 0);
    let root = pool.get_root();

    let recipient: ContractAddress = 0x789.try_into().unwrap();
    let proof: Array<felt252> = array![1];
    kakarot.evm_withdraw(proof.span(), root, (0xDA01, 0xDA02), 0xCB01, recipient, 700, 0);

    assert!(kakarot.get_pool_balance(0) == 800, "1500 - 700 = 800");
    assert!(kakarot.is_nullifier_spent(0xDA01), "withdraw nf1 spent");
}

// ─── Fee Estimation ─────────────────────────────────────────────

#[test]
fn test_kakarot_fee_estimation_basic() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000); // 1x factor
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    // amount=10000, gas=21000
    let (protocol_fee, gas_premium, total) = kakarot.estimate_evm_fee(10000, 21000);

    // protocol_fee = 10000 * 10 / 10000 = 10
    assert!(protocol_fee == 10, "protocol fee = 10");
    // gas_premium = 21000 * 10000 / 10000 = 21000
    assert!(gas_premium == 21000, "gas premium = 21000");
    assert!(total == 21010, "total = 21010");
}

#[test]
fn test_kakarot_fee_estimation_with_factor() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 15000); // 1.5x factor
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    let (protocol_fee, gas_premium, total) = kakarot.estimate_evm_fee(10000, 20000);

    // protocol_fee = 10000 * 10 / 10000 = 10
    assert!(protocol_fee == 10, "protocol fee stays 10");
    // gas_premium = 20000 * 15000 / 10000 = 30000
    assert!(gas_premium == 30000, "gas premium with 1.5x factor");
    assert!(total == 30010, "total = 30010");
}

#[test]
fn test_kakarot_update_gas_price_factor() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    assert!(kakarot.get_gas_price_factor() == 10000, "initial factor");

    kakarot.set_gas_price_factor(20000);
    assert!(kakarot.get_gas_price_factor() == 20000, "updated factor");

    let (_pf, gas_premium, _t) = kakarot.estimate_evm_fee(10000, 10000);
    // gas_premium = 10000 * 20000 / 10000 = 20000
    assert!(gas_premium == 20000, "premium with 2x factor");
}

// ─── Pause / Unpause ─────────────────────────────────────────────

#[test]
fn test_kakarot_pause_blocks_deposits() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    kakarot.pause();

    // Views still work when paused
    assert!(kakarot.get_leaf_count() == 0, "view works while paused");
    assert!(kakarot.get_gas_price_factor() == 10000, "fee view works while paused");
}

#[test]
fn test_kakarot_unpause_re_enables() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    kakarot.pause();
    kakarot.unpause();

    // Should work again after unpause
    kakarot.evm_deposit(0xAFAF, 100, 0);
    assert!(kakarot.get_leaf_count() == 1, "deposit works after unpause");
}

#[test]
#[should_panic(expected: "adapter is paused")]
fn test_kakarot_deposit_while_paused_panics() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    kakarot.pause();
    kakarot.evm_deposit(0xBEEF, 100, 0);
}

#[test]
#[should_panic(expected: "already paused")]
fn test_kakarot_double_pause_panics() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    kakarot.pause();
    kakarot.pause();
}

#[test]
#[should_panic(expected: "adapter is paused")]
fn test_kakarot_transfer_while_paused_panics() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    kakarot.pause();

    let proof: Array<felt252> = array![1];
    kakarot.evm_transfer(proof.span(), 0x123, (0x1, 0x2), (0x3, 0x4));
}

#[test]
#[should_panic(expected: "adapter is paused")]
fn test_kakarot_withdraw_while_paused_panics() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    kakarot.pause();

    let recipient: ContractAddress = 0x789.try_into().unwrap();
    let proof: Array<felt252> = array![1];
    kakarot.evm_withdraw(proof.span(), 0x123, (0x1, 0x2), 0x4, recipient, 5, 0);
}

// ─── Multi-Adapter: Kakarot + Madara on Same Pool ────────────────

#[test]
fn test_kakarot_and_madara_share_pool_state() {
    let pool_addr = deploy_pool();
    let epoch_addr = deploy_epoch_manager();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let madara_addr = deploy_madara_adapter(CHAIN_MADARA, pool_addr, epoch_addr);

    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    // Deposit via Kakarot
    kakarot.evm_deposit(0xCA01, 1000, 0);

    // Deposit directly via pool (simulating Madara-routed deposit)
    pool.deposit(0xDA01, 500, 0);

    // Both adapters see unified state
    assert!(kakarot.get_leaf_count() == 2, "kakarot sees 2 leaves");
    assert!(pool.get_leaf_count() == 2, "pool sees 2 leaves");
    assert!(kakarot.get_pool_balance(0) == 1500, "kakarot balance = 1500");
}

#[test]
fn test_kakarot_deposit_then_madara_lock_flow() {
    let pool_addr = deploy_pool();
    let epoch_addr = deploy_epoch_manager();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let madara_addr = deploy_madara_adapter(CHAIN_STARKNET, pool_addr, epoch_addr);
    let madara = IMadaraAdapterDispatcher { contract_address: madara_addr };

    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };
    let epoch = IEpochManagerDispatcher { contract_address: epoch_addr };

    // 1. Deposit via Kakarot EVM bridge
    kakarot.evm_deposit(0xCAFE, 1000, 0);
    assert!(kakarot.get_leaf_count() == 1, "1 leaf after kakarot deposit");

    // 2. Record nullifier in epoch manager (simulating pool consuming note)
    epoch.record_nullifier(0xEEAF);
    epoch.advance_epoch();

    let epoch_root = epoch.get_epoch_root(1);
    assert!(epoch_root != 0, "epoch root should be nonzero");

    // 3. Register peer and lock for Madara appchain
    let peer: ContractAddress = 0x777.try_into().unwrap();
    madara.register_peer(CHAIN_MADARA, peer);
    madara.lock_for_appchain(0xB01DED, CHAIN_MADARA, (0xAF1, 0xAF2), 0xA01E);

    assert!(madara.get_outbound_count(CHAIN_MADARA) == 1, "1 outbound lock");
}

// ─── Cross-chain Full Flow: Lock → Sync → Receive ───────────────

#[test]
fn test_full_kakarot_to_madara_flow() {
    // Deploy two pool contexts (source: Starknet, dest: Madara)
    let pool_src = deploy_pool();
    let pool_dst = deploy_pool();
    let epoch_src = deploy_epoch_manager();
    let epoch_dst_addr = deploy_epoch_manager();

    let kakarot = IKakarotAdapterDispatcher {
        contract_address: deploy_kakarot_adapter(pool_src, 10000),
    };
    let madara_src = IMadaraAdapterDispatcher {
        contract_address: deploy_madara_adapter(CHAIN_STARKNET, pool_src, epoch_src),
    };
    let madara_dst = IMadaraAdapterDispatcher {
        contract_address: deploy_madara_adapter(CHAIN_MADARA, pool_dst, epoch_dst_addr),
    };
    let epoch = IEpochManagerDispatcher { contract_address: epoch_src };
    let pool = IPrivacyPoolDispatcher { contract_address: pool_src };

    // Register peers
    madara_src.register_peer(CHAIN_MADARA, madara_dst.contract_address);
    madara_dst.register_peer(CHAIN_STARKNET, madara_src.contract_address);

    // 1. Deposit via EVM/Kakarot on source chain
    kakarot.evm_deposit(0xEAB01, 2000, 0);
    assert!(pool.get_pool_balance(0) == 2000, "source pool has 2000");

    // 2. Lock commitment on source Madara adapter for transport
    madara_src.lock_for_appchain(0xA0C1ED, CHAIN_MADARA, (0xAB1, 0xAB2), 0x51CDA);
    assert!(madara_src.get_outbound_count(CHAIN_MADARA) == 1, "1 outbound");

    // 3. Sync epoch root from source to destination
    epoch.record_nullifier(0xAB1);
    epoch.advance_epoch();
    let epoch_root = epoch.get_epoch_root(1);

    madara_dst.sync_epoch_root(CHAIN_STARKNET, 1, epoch_root);
    assert!(madara_dst.get_peer_epoch_root(CHAIN_STARKNET, 1) == epoch_root, "synced root");

    // 4. Receive on destination chain
    madara_dst.receive_from_appchain(0xA0C1ED, CHAIN_STARKNET, 1, epoch_root, 0x51CDA);
    assert!(madara_dst.get_inbound_count(CHAIN_STARKNET) == 1, "1 inbound on dest");
}

// ─── Known Root Verification via KakarotAdapter ──────────────────

#[test]
fn test_kakarot_root_history() {
    let pool_addr = deploy_pool();
    let kakarot_addr = deploy_kakarot_adapter(pool_addr, 10000);
    let pool = IPrivacyPoolDispatcher { contract_address: pool_addr };
    let kakarot = IKakarotAdapterDispatcher { contract_address: kakarot_addr };

    let root_0 = kakarot.get_root();
    pool.deposit(0xAA, 100, 0);
    let root_1 = kakarot.get_root();

    assert!(root_0 != root_1, "root changes after deposit");
    assert!(kakarot.is_known_root(root_0), "initial root is known");
    assert!(kakarot.is_known_root(root_1), "current root is known");
    assert!(!kakarot.is_known_root(0xDEADBEEF), "random root is not known");
}
