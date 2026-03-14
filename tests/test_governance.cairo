use core::poseidon::poseidon_hash_span;
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
    start_cheat_block_timestamp_global,
};
use starknet::ContractAddress;
use starkprivacy_security::timelock::{ITimelockDispatcher, ITimelockDispatcherTrait};
use starkprivacy_security::multisig::{IMultiSigDispatcher, IMultiSigDispatcherTrait};
use starkprivacy_security::upgradeable::{IUpgradeableProxyDispatcher, IUpgradeableProxyDispatcherTrait};
use starknet::ClassHash;

fn owner() -> ContractAddress {
    starknet::contract_address_const::<0x1>()
}

fn signer_a() -> ContractAddress {
    starknet::contract_address_const::<0xA>()
}

fn signer_b() -> ContractAddress {
    starknet::contract_address_const::<0xB>()
}

fn signer_c() -> ContractAddress {
    starknet::contract_address_const::<0xC>()
}

// ─── Timelock ────────────────────────────────────────────────────

fn deploy_timelock(proposer: ContractAddress, min_delay: u64) -> ITimelockDispatcher {
    let contract = declare("Timelock").unwrap().contract_class();
    let (addr, _) = contract
        .deploy(@array![proposer.into(), min_delay.into()])
        .unwrap();
    ITimelockDispatcher { contract_address: addr }
}

#[test]
fn test_timelock_initial_state() {
    let tl = deploy_timelock(owner(), 3600);
    assert!(tl.get_min_delay() == 3600, "min delay mismatch");
}

#[test]
fn test_timelock_queue_and_check_pending() {
    let tl = deploy_timelock(owner(), 60);
    start_cheat_caller_address(tl.contract_address, owner());
    start_cheat_block_timestamp_global(1000);

    let target: ContractAddress = 0x999.try_into().unwrap();
    let op_id = tl.queue(target, 'update', 0xABC, 60);

    assert!(tl.is_pending(op_id), "should be pending");
    assert!(!tl.is_ready(op_id), "should not be ready yet");
}

#[test]
fn test_timelock_execute_after_delay() {
    let tl = deploy_timelock(owner(), 60);
    start_cheat_caller_address(tl.contract_address, owner());
    start_cheat_block_timestamp_global(1000);

    // Use timelock itself as target: call update_min_delay(120)
    let target = tl.contract_address;
    let selector = selector!("update_min_delay");
    let calldata: Array<felt252> = array![120]; // new_delay = 120
    let calldata_hash = poseidon_hash_span(calldata.span());
    let op_id = tl.queue(target, selector, calldata_hash, 60);

    // Advance time past delay
    start_cheat_block_timestamp_global(1061);
    assert!(tl.is_ready(op_id), "should be ready after delay");

    tl.execute(op_id, calldata.span());
    assert!(!tl.is_pending(op_id), "should no longer be pending");
    // Verify the cross-contract call actually updated the delay
    assert!(tl.get_min_delay() == 120, "delay should have been updated by execute");
}

#[test]
#[should_panic(expected: "too early")]
fn test_timelock_execute_too_early_rejected() {
    let tl = deploy_timelock(owner(), 60);
    start_cheat_caller_address(tl.contract_address, owner());
    start_cheat_block_timestamp_global(1000);

    let target = tl.contract_address;
    let selector = selector!("update_min_delay");
    let calldata: Array<felt252> = array![120];
    let calldata_hash = poseidon_hash_span(calldata.span());
    let op_id = tl.queue(target, selector, calldata_hash, 60);

    // Try to execute immediately
    tl.execute(op_id, calldata.span());
}

#[test]
fn test_timelock_cancel() {
    let tl = deploy_timelock(owner(), 60);
    start_cheat_caller_address(tl.contract_address, owner());
    start_cheat_block_timestamp_global(1000);

    let target: ContractAddress = 0x999.try_into().unwrap();
    let op_id = tl.queue(target, 'update', 0xABC, 60);

    tl.cancel(op_id);
    assert!(!tl.is_pending(op_id), "should not be pending after cancel");
}

#[test]
#[should_panic(expected: "only proposer can queue")]
fn test_timelock_queue_non_proposer_rejected() {
    let tl = deploy_timelock(owner(), 60);
    let other: ContractAddress = 0x42.try_into().unwrap();
    start_cheat_caller_address(tl.contract_address, other);
    start_cheat_block_timestamp_global(1000);

    let target: ContractAddress = 0x999.try_into().unwrap();
    tl.queue(target, 'update', 0xABC, 60);
}

#[test]
#[should_panic(expected: "delay below minimum")]
fn test_timelock_delay_below_min_rejected() {
    let tl = deploy_timelock(owner(), 3600);
    start_cheat_caller_address(tl.contract_address, owner());
    start_cheat_block_timestamp_global(1000);

    let target: ContractAddress = 0x999.try_into().unwrap();
    tl.queue(target, 'update', 0xABC, 60); // below 3600
}

#[test]
fn test_timelock_update_min_delay() {
    let tl = deploy_timelock(owner(), 60);
    start_cheat_caller_address(tl.contract_address, owner());

    tl.update_min_delay(120);
    assert!(tl.get_min_delay() == 120, "delay should be updated");
}

// ─── MultiSig ────────────────────────────────────────────────────

fn deploy_multisig(threshold: u32, count: u32) -> IMultiSigDispatcher {
    let contract = declare("MultiSig").unwrap().contract_class();
    let (addr, _) = contract
        .deploy(
            @array![
                threshold.into(),
                count.into(),
                signer_a().into(),
                signer_b().into(),
                signer_c().into(),
            ],
        )
        .unwrap();
    IMultiSigDispatcher { contract_address: addr }
}

#[test]
fn test_multisig_initial_state() {
    let ms = deploy_multisig(2, 3);
    assert!(ms.get_threshold() == 2, "threshold mismatch");
    assert!(ms.get_signer_count() == 3, "signer count mismatch");
    assert!(ms.is_signer(signer_a()), "A should be signer");
    assert!(ms.is_signer(signer_b()), "B should be signer");
    assert!(ms.is_signer(signer_c()), "C should be signer");
    assert!(!ms.is_signer(owner()), "owner should not be signer");
}

#[test]
fn test_multisig_propose_auto_approves() {
    let ms = deploy_multisig(2, 3);
    start_cheat_caller_address(ms.contract_address, signer_a());

    let target: ContractAddress = 0x999.try_into().unwrap();
    let id = ms.propose(target, 'do_thing', 0xABC);

    // Proposer auto-approves
    assert!(ms.get_approval_count(id) == 1, "should have 1 approval");
    assert!(!ms.is_approved(id), "should not be approved yet (need 2)");
}

#[test]
fn test_multisig_reaches_threshold() {
    let ms = deploy_multisig(2, 3);
    start_cheat_caller_address(ms.contract_address, signer_a());

    let target: ContractAddress = 0x999.try_into().unwrap();
    let id = ms.propose(target, 'do_thing', 0xABC);

    // Second signer approves
    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.approve(id);

    assert!(ms.get_approval_count(id) == 2, "should have 2 approvals");
    assert!(ms.is_approved(id), "should be approved (threshold 2)");
}

#[test]
fn test_multisig_revoke_drops_below_threshold() {
    let ms = deploy_multisig(2, 3);
    start_cheat_caller_address(ms.contract_address, signer_a());

    let target: ContractAddress = 0x999.try_into().unwrap();
    let id = ms.propose(target, 'do_thing', 0xABC);

    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.approve(id);
    assert!(ms.is_approved(id), "should be approved");

    // Revoke
    ms.revoke(id);
    assert!(!ms.is_approved(id), "should no longer be approved");
    assert!(ms.get_approval_count(id) == 1, "should have 1 approval");
}

#[test]
#[should_panic(expected: "not a signer")]
fn test_multisig_non_signer_propose_rejected() {
    let ms = deploy_multisig(2, 3);
    start_cheat_caller_address(ms.contract_address, owner()); // not a signer

    let target: ContractAddress = 0x999.try_into().unwrap();
    ms.propose(target, 'do_thing', 0xABC);
}

#[test]
#[should_panic(expected: "already approved")]
fn test_multisig_double_approve_rejected() {
    let ms = deploy_multisig(2, 3);
    start_cheat_caller_address(ms.contract_address, signer_a());

    let target: ContractAddress = 0x999.try_into().unwrap();
    let id = ms.propose(target, 'do_thing', 0xABC);
    ms.approve(id); // Already auto-approved
}

#[test]
fn test_multisig_three_of_three() {
    let ms = deploy_multisig(3, 3);
    start_cheat_caller_address(ms.contract_address, signer_a());

    let target: ContractAddress = 0x999.try_into().unwrap();
    let id = ms.propose(target, 'action', 0);

    assert!(!ms.is_approved(id), "need 3, only have 1");

    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.approve(id);
    assert!(!ms.is_approved(id), "need 3, only have 2");

    start_cheat_caller_address(ms.contract_address, signer_c());
    ms.approve(id);
    assert!(ms.is_approved(id), "should be approved now (3/3)");
}

// ─── Timelock: get_proposer ──────────────────────────────────────

#[test]
fn test_timelock_get_proposer() {
    let tl = deploy_timelock(owner(), 60);
    assert!(tl.get_proposer() == owner(), "proposer should be owner");
}

// ─── Timelock: calldata hash mismatch ────────────────────────────

#[test]
#[should_panic(expected: "calldata hash mismatch")]
fn test_timelock_execute_calldata_mismatch() {
    let tl = deploy_timelock(owner(), 60);
    start_cheat_caller_address(tl.contract_address, owner());
    start_cheat_block_timestamp_global(1000);

    let target = tl.contract_address;
    let selector = selector!("update_min_delay");
    let calldata: Array<felt252> = array![120];
    let calldata_hash = poseidon_hash_span(calldata.span());
    let op_id = tl.queue(target, selector, calldata_hash, 60);

    start_cheat_block_timestamp_global(1061);

    // Provide wrong calldata
    let wrong_calldata: Array<felt252> = array![999];
    tl.execute(op_id, wrong_calldata.span());
}

// ─── MultiSig: set_timelock ─────────────────────────────────────

#[test]
fn test_multisig_set_timelock() {
    let ms = deploy_multisig(2, 3);
    let tl = deploy_timelock(owner(), 60);

    // Requires M-of-N threshold: first signer records approval
    start_cheat_caller_address(ms.contract_address, signer_a());
    ms.set_timelock(tl.contract_address);
    // Not yet set (1 < threshold of 2)
    let zero: ContractAddress = 0.try_into().unwrap();
    assert!(ms.get_timelock() == zero, "timelock should not be set yet");

    // Second signer reaches threshold
    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.set_timelock(tl.contract_address);
    assert!(ms.get_timelock() == tl.contract_address, "timelock should be set after threshold");
}

#[test]
#[should_panic(expected: "already approved timelock")]
fn test_multisig_set_timelock_double_approve_rejected() {
    let ms = deploy_multisig(2, 3);
    let tl = deploy_timelock(owner(), 60);

    start_cheat_caller_address(ms.contract_address, signer_a());
    ms.set_timelock(tl.contract_address);
    // Same signer tries again — should panic
    ms.set_timelock(tl.contract_address);
}

#[test]
#[should_panic(expected: "timelock already set")]
fn test_multisig_set_timelock_twice_rejected() {
    let ms = deploy_multisig(2, 3);
    let tl = deploy_timelock(owner(), 60);

    // First: set timelock with threshold approvals
    start_cheat_caller_address(ms.contract_address, signer_a());
    ms.set_timelock(tl.contract_address);
    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.set_timelock(tl.contract_address);
    // Now timelock is set. Third signer tries — should fail with "timelock already set"
    start_cheat_caller_address(ms.contract_address, signer_c());
    ms.set_timelock(tl.contract_address);
}

#[test]
#[should_panic(expected: "not a signer")]
fn test_multisig_set_timelock_non_signer_rejected() {
    let ms = deploy_multisig(2, 3);
    let tl = deploy_timelock(owner(), 60);

    start_cheat_caller_address(ms.contract_address, owner()); // not a signer
    ms.set_timelock(tl.contract_address);
}

// ─── MultiSig: forward_to_timelock ──────────────────────────────

#[test]
fn test_multisig_forward_to_timelock() {
    let ms = deploy_multisig(2, 3);
    // Timelock with multisig as proposer
    let tl = deploy_timelock(ms.contract_address, 60);

    // Set timelock on multisig (requires 2-of-3 threshold)
    start_cheat_caller_address(ms.contract_address, signer_a());
    ms.set_timelock(tl.contract_address);
    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.set_timelock(tl.contract_address);

    // Propose an operation
    start_cheat_caller_address(ms.contract_address, signer_a());
    let target: ContractAddress = 0x999.try_into().unwrap();
    let calldata_hash: felt252 = 0xABC;
    let id = ms.propose(target, 'do_thing', calldata_hash);

    // Second signer approves
    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.approve(id);
    assert!(ms.is_approved(id), "should be approved");

    // Set block timestamp for timelock queue
    start_cheat_block_timestamp_global(1000);

    // Forward to timelock
    start_cheat_caller_address(ms.contract_address, signer_a());
    let op_id = ms.forward_to_timelock(id);

    // Verify the operation is queued in the timelock
    assert!(tl.is_pending(op_id), "should be pending in timelock");
}

#[test]
#[should_panic(expected: "not enough approvals")]
fn test_multisig_forward_insufficient_approvals_rejected() {
    let ms = deploy_multisig(2, 3);
    let tl = deploy_timelock(ms.contract_address, 60);

    start_cheat_caller_address(ms.contract_address, signer_a());
    ms.set_timelock(tl.contract_address);
    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.set_timelock(tl.contract_address);

    start_cheat_caller_address(ms.contract_address, signer_a());
    let target: ContractAddress = 0x999.try_into().unwrap();
    let id = ms.propose(target, 'do_thing', 0xABC);
    // Only 1 approval (from proposer), need 2
    ms.forward_to_timelock(id);
}

#[test]
#[should_panic(expected: "already executed")]
fn test_multisig_forward_twice_rejected() {
    let ms = deploy_multisig(2, 3);
    let tl = deploy_timelock(ms.contract_address, 60);

    start_cheat_caller_address(ms.contract_address, signer_a());
    ms.set_timelock(tl.contract_address);
    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.set_timelock(tl.contract_address);

    start_cheat_caller_address(ms.contract_address, signer_a());
    let target: ContractAddress = 0x999.try_into().unwrap();
    let id = ms.propose(target, 'do_thing', 0xABC);

    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.approve(id);

    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(ms.contract_address, signer_a());
    ms.forward_to_timelock(id);
    // Second forward should fail
    ms.forward_to_timelock(id);
}

#[test]
#[should_panic(expected: "timelock not set")]
fn test_multisig_forward_without_timelock_rejected() {
    let ms = deploy_multisig(2, 3);

    start_cheat_caller_address(ms.contract_address, signer_a());
    let target: ContractAddress = 0x999.try_into().unwrap();
    let id = ms.propose(target, 'do_thing', 0xABC);

    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.approve(id);

    start_cheat_caller_address(ms.contract_address, signer_a());
    ms.forward_to_timelock(id);
}

// ─── End-to-end: MultiSig → Timelock → Execute ──────────────────

#[test]
fn test_full_governance_flow() {
    // Deploy timelock with multisig as proposer, min_delay=60
    let ms = deploy_multisig(2, 3);
    let tl = deploy_timelock(ms.contract_address, 60);

    // Wire multisig to timelock (requires 2-of-3)
    start_cheat_caller_address(ms.contract_address, signer_a());
    ms.set_timelock(tl.contract_address);
    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.set_timelock(tl.contract_address);

    // Propose: update timelock's min_delay to 120
    start_cheat_caller_address(ms.contract_address, signer_a());
    let target = tl.contract_address;
    let selector = selector!("update_min_delay");
    let calldata: Array<felt252> = array![120];
    let calldata_hash = poseidon_hash_span(calldata.span());
    let prop_id = ms.propose(target, selector, calldata_hash);

    // Approve to threshold
    start_cheat_caller_address(ms.contract_address, signer_b());
    ms.approve(prop_id);

    // Forward to timelock
    start_cheat_block_timestamp_global(1000);
    start_cheat_caller_address(ms.contract_address, signer_a());
    let op_id = ms.forward_to_timelock(prop_id);
    assert!(tl.is_pending(op_id), "op should be pending");

    // Advance time past delay and execute
    start_cheat_block_timestamp_global(1061);
    // Execute needs to be called by someone — the timelock checks pending, not caller
    start_cheat_caller_address(tl.contract_address, ms.contract_address);
    tl.execute(op_id, calldata.span());

    assert!(!tl.is_pending(op_id), "op should no longer be pending");
    assert!(tl.get_min_delay() == 120, "delay should have been updated to 120");
}

// ─── UpgradeableProxy ────────────────────────────────────────────

fn deploy_proxy(governor: ContractAddress, emergency: ContractAddress) -> IUpgradeableProxyDispatcher {
    let contract = declare("UpgradeableProxy").unwrap().contract_class();
    // Use the proxy's own class hash as initial_class_hash for testing
    let class_hash: ClassHash = (*contract.class_hash).into();
    let calldata: Array<felt252> = array![class_hash.into(), governor.into(), emergency.into()];
    let (addr, _) = contract.deploy(@calldata).unwrap();
    IUpgradeableProxyDispatcher { contract_address: addr }
}

#[test]
fn test_proxy_initial_state() {
    let proxy = deploy_proxy(owner(), signer_a());
    start_cheat_caller_address(proxy.contract_address, owner());

    assert!(proxy.get_governor() == owner(), "governor should be owner");
    assert!(proxy.get_emergency_governor() == signer_a(), "emergency should be signer_a");
    assert!(proxy.get_upgrade_count() == 0, "no upgrades yet");
}

#[test]
fn test_proxy_governor_can_set_governor() {
    let proxy = deploy_proxy(owner(), signer_a());
    start_cheat_caller_address(proxy.contract_address, owner());

    proxy.set_governor(signer_b());
    assert!(proxy.get_governor() == signer_b(), "governor updated");
}

#[test]
fn test_proxy_governor_can_set_emergency() {
    let proxy = deploy_proxy(owner(), signer_a());
    start_cheat_caller_address(proxy.contract_address, owner());

    proxy.set_emergency_governor(signer_c());
    assert!(proxy.get_emergency_governor() == signer_c(), "emergency updated");
}

#[test]
#[should_panic(expected: "caller is not governor")]
fn test_proxy_non_governor_cannot_set_governor() {
    let proxy = deploy_proxy(owner(), signer_a());
    start_cheat_caller_address(proxy.contract_address, signer_b());

    proxy.set_governor(signer_c());
}

#[test]
#[should_panic(expected: "caller is not authorized to upgrade")]
fn test_proxy_unauthorized_upgrade_rejected() {
    let proxy = deploy_proxy(owner(), signer_a());
    start_cheat_caller_address(proxy.contract_address, signer_b());

    // Use some class hash — doesn't matter, should panic before syscall
    let fake_hash: ClassHash = 0xDEAD.try_into().unwrap();
    proxy.upgrade(fake_hash);
}

#[test]
#[should_panic(expected: "class hash cannot be zero")]
fn test_proxy_zero_class_hash_rejected() {
    let proxy = deploy_proxy(owner(), signer_a());
    start_cheat_caller_address(proxy.contract_address, owner());

    let zero_hash: ClassHash = 0.try_into().unwrap();
    proxy.upgrade(zero_hash);
}

#[test]
#[should_panic(expected: "already at this version")]
fn test_proxy_same_class_hash_rejected() {
    let proxy = deploy_proxy(owner(), signer_a());
    start_cheat_caller_address(proxy.contract_address, owner());

    let current = proxy.get_implementation();
    proxy.upgrade(current);
}

#[test]
fn test_proxy_emergency_governor_can_upgrade() {
    let proxy = deploy_proxy(owner(), signer_a());

    // Verify upgrade count is 0 before upgrade
    assert!(proxy.get_upgrade_count() == 0, "no upgrades yet");

    // Emergency governor should also be authorized
    start_cheat_caller_address(proxy.contract_address, signer_a());

    // Use a different class hash — declare a second UpgradeableProxy to get a distinct hash
    // Actually, we use MultiSig class hash. After replace_class, the contract changes ABI.
    // So we just verify the call doesn't revert (i.e., authorization passes).
    // We'll upgrade to a copy of the same proxy class by re-declaring.
    let ms_class = declare("MultiSig").unwrap().contract_class();
    let new_hash: ClassHash = (*ms_class.class_hash).into();

    // This will succeed (auth check passes, replace_class runs).
    // After this call, the contract is now a MultiSig — we can't call proxy methods.
    // We just verify it doesn't panic, proving emergency governor is authorized.
    proxy.upgrade(new_hash);
    // If we reach here, the emergency governor was authorized ✓
}

#[test]
#[should_panic(expected: "governor cannot be zero")]
fn test_proxy_governor_cannot_be_zero() {
    let proxy = deploy_proxy(owner(), signer_a());
    start_cheat_caller_address(proxy.contract_address, owner());

    let zero: ContractAddress = 0.try_into().unwrap();
    proxy.set_governor(zero);
}
