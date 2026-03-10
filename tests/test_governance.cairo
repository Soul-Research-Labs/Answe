use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
    start_cheat_block_timestamp_global,
};
use starknet::ContractAddress;
use starkprivacy_security::timelock::{ITimelockDispatcher, ITimelockDispatcherTrait};
use starkprivacy_security::multisig::{IMultiSigDispatcher, IMultiSigDispatcherTrait};

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

    let target: ContractAddress = 0x999.try_into().unwrap();
    let op_id = tl.queue(target, 'update', 0xABC, 60);

    // Advance time past delay
    start_cheat_block_timestamp_global(1061);
    assert!(tl.is_ready(op_id), "should be ready after delay");

    tl.execute(op_id);
    assert!(!tl.is_pending(op_id), "should no longer be pending");
}

#[test]
#[should_panic(expected: "too early")]
fn test_timelock_execute_too_early_rejected() {
    let tl = deploy_timelock(owner(), 60);
    start_cheat_caller_address(tl.contract_address, owner());
    start_cheat_block_timestamp_global(1000);

    let target: ContractAddress = 0x999.try_into().unwrap();
    let op_id = tl.queue(target, 'update', 0xABC, 60);

    // Try to execute immediately
    tl.execute(op_id);
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
