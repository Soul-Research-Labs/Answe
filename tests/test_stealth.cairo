use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

use starkprivacy_stealth::registry::IStealthRegistryDispatcher;
use starkprivacy_stealth::registry::IStealthRegistryDispatcherTrait;
use starkprivacy_stealth::encrypted_note::{compute_scan_tag, pad_note_payload, NOTE_PADDED_SIZE};

fn deploy_stealth_registry() -> ContractAddress {
    let contract = declare("StealthRegistry").unwrap().contract_class();
    let calldata: Array<felt252> = array![];
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

// ─── StealthRegistry Tests ─────────────────────────────────────

#[test]
fn test_stealth_initial_state() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    assert!(registry.get_ephemeral_count() == 0, "initial ephemeral count should be 0");
}

#[test]
fn test_register_meta_address() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    let spending_pub: felt252 = 0xABCD1234;
    let viewing_pub: felt252 = 0xDEAD5678;

    registry.register_meta_address(spending_pub, viewing_pub);

    let caller: ContractAddress = starknet::get_contract_address();
    let (stored_spending, stored_viewing) = registry.get_meta_address(caller);
    assert!(stored_spending == spending_pub, "spending pub key mismatch");
    assert!(stored_viewing == viewing_pub, "viewing pub key mismatch");
}

#[test]
fn test_publish_ephemeral_key() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    let eph_pub: felt252 = 0xE1F001;
    let commitment: felt252 = 0xC0AA1101;
    let encrypted_note: Array<felt252> = array![0x1, 0x2, 0x3];
    let scan_tag: felt252 = 0xFA61;

    registry.publish_ephemeral_key(eph_pub, encrypted_note.span(), commitment, scan_tag);

    assert!(registry.get_ephemeral_count() == 1, "ephemeral count should be 1");

    let (stored_pub, stored_commitment) = registry.get_ephemeral_at(0);
    assert!(stored_pub == eph_pub, "ephemeral pub key mismatch");
    assert!(stored_commitment == commitment, "commitment mismatch");
}

#[test]
fn test_multiple_ephemeral_keys() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    registry.publish_ephemeral_key(0xE001, array![].span(), 0xC001, 0);
    registry.publish_ephemeral_key(0xE002, array![].span(), 0xC002, 0);
    registry.publish_ephemeral_key(0xE003, array![].span(), 0xC003, 0);

    assert!(registry.get_ephemeral_count() == 3, "should have 3 ephemeral keys");

    let (pub1, cm1) = registry.get_ephemeral_at(0);
    let (pub2, cm2) = registry.get_ephemeral_at(1);
    let (pub3, cm3) = registry.get_ephemeral_at(2);

    assert!(pub1 == 0xE001, "first ephemeral pub mismatch");
    assert!(pub2 == 0xE002, "second ephemeral pub mismatch");
    assert!(pub3 == 0xE003, "third ephemeral pub mismatch");
    assert!(cm1 == 0xC001, "first commitment mismatch");
    assert!(cm2 == 0xC002, "second commitment mismatch");
    assert!(cm3 == 0xC003, "third commitment mismatch");
}

#[test]
fn test_register_meta_then_publish() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    registry.register_meta_address(0x5AE0D, 0xF1E3);
    registry.publish_ephemeral_key(0xE1F, array![0x1, 0x2].span(), 0xCA, 0);

    let caller: ContractAddress = starknet::get_contract_address();
    let (sp, vw) = registry.get_meta_address(caller);
    assert!(sp == 0x5AE0D, "spending key mismatch after publish");
    assert!(vw == 0xF1E3, "viewing key mismatch after publish");
    assert!(registry.get_ephemeral_count() == 1, "ephemeral count mismatch");
}

// ─── Encrypted Note Storage Tests ──────────────────────────────

#[test]
fn test_encrypted_note_stored_and_retrieved() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    let note_data: Array<felt252> = array![0xAA, 0xBB, 0xCC, 0xDD];
    registry.publish_ephemeral_key(0xE1, note_data.span(), 0xC1, 0x5CA0);

    let retrieved = registry.get_encrypted_note_at(0);
    assert!(retrieved.len() == 4, "note length mismatch");
    assert!(*retrieved[0] == 0xAA, "note[0] mismatch");
    assert!(*retrieved[1] == 0xBB, "note[1] mismatch");
    assert!(*retrieved[2] == 0xCC, "note[2] mismatch");
    assert!(*retrieved[3] == 0xDD, "note[3] mismatch");
}

#[test]
fn test_encrypted_note_empty() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    registry.publish_ephemeral_key(0xE1, array![].span(), 0xC1, 0);

    let retrieved = registry.get_encrypted_note_at(0);
    assert!(retrieved.len() == 0, "empty note should have length 0");
}

#[test]
fn test_scan_tag_stored_and_retrieved() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    let tag = compute_scan_tag(0xF1E3, 0xE1F, 1);
    registry.publish_ephemeral_key(0xE1F, array![0x1].span(), 0xCA, tag);

    let stored_tag = registry.get_scan_tag_at(0);
    assert!(stored_tag == tag, "scan tag mismatch");
}

#[test]
fn test_scan_tag_filtering_multiple() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    let my_tag = compute_scan_tag(0xF1E3, 0xAE01, 1);
    let other_tag = compute_scan_tag(0xD1CE, 0xAE02, 1);

    registry.publish_ephemeral_key(0xAE01, array![0x1].span(), 0xC1, my_tag);
    registry.publish_ephemeral_key(0xAE02, array![0x2].span(), 0xC2, other_tag);
    registry.publish_ephemeral_key(0xAE03, array![0x3].span(), 0xC3, my_tag);

    // Scan: check which entries match our expected tag
    let count = registry.get_ephemeral_count();
    let mut matches: u64 = 0;
    let mut i: u64 = 0;
    while i < count {
        if registry.get_scan_tag_at(i) == my_tag {
            matches += 1;
        }
        i += 1;
    };
    assert!(matches == 2, "should find 2 matching scan tags");
}

#[test]
fn test_multiple_notes_independent_storage() {
    let address = deploy_stealth_registry();
    let registry = IStealthRegistryDispatcher { contract_address: address };

    registry.publish_ephemeral_key(0xE1, array![0x10, 0x20].span(), 0xC1, 0);
    registry.publish_ephemeral_key(0xE2, array![0x30, 0x40, 0x50].span(), 0xC2, 0);

    let note0 = registry.get_encrypted_note_at(0);
    let note1 = registry.get_encrypted_note_at(1);

    assert!(note0.len() == 2, "first note length");
    assert!(note1.len() == 3, "second note length");
    assert!(*note0[0] == 0x10, "note0[0]");
    assert!(*note1[0] == 0x30, "note1[0]");
    assert!(*note1[2] == 0x50, "note1[2]");
}

// ─── EncryptedNote Library Tests ────────────────────────────────

#[test]
fn test_scan_tag_deterministic() {
    let tag1 = compute_scan_tag(0xF1E3, 0xE1F, 1);
    let tag2 = compute_scan_tag(0xF1E3, 0xE1F, 1);
    assert!(tag1 == tag2, "scan tags should be deterministic");
}

#[test]
fn test_scan_tag_different_epoch() {
    let tag1 = compute_scan_tag(0xF1E3, 0xE1F, 1);
    let tag2 = compute_scan_tag(0xF1E3, 0xE1F, 2);
    assert!(tag1 != tag2, "different epochs should produce different scan tags");
}

#[test]
fn test_scan_tag_different_keys() {
    let tag1 = compute_scan_tag(0xF1E301, 0xE1F, 1);
    let tag2 = compute_scan_tag(0xF1E302, 0xE1F, 1);
    assert!(tag1 != tag2, "different viewing keys should produce different scan tags");
}

#[test]
fn test_pad_note_short_payload() {
    let payload: Array<felt252> = array![0x1, 0x2];
    let padded = pad_note_payload(payload.span());
    assert!(padded.len() == NOTE_PADDED_SIZE, "padded should be NOTE_PADDED_SIZE");
    assert!(*padded[0] == 0x1, "first element preserved");
    assert!(*padded[1] == 0x2, "second element preserved");
}

#[test]
fn test_pad_note_exact_payload() {
    let mut payload: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i < NOTE_PADDED_SIZE {
        payload.append(i.into());
        i += 1;
    };
    let padded = pad_note_payload(payload.span());
    assert!(padded.len() == NOTE_PADDED_SIZE, "exact-size should remain NOTE_PADDED_SIZE");
}
