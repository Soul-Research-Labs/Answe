use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

use starkprivacy_compliance::sanctions::ISanctionsOracleDispatcher;
use starkprivacy_compliance::sanctions::ISanctionsOracleDispatcherTrait;
use starkprivacy_compliance::oracle::IComplianceOracleDispatcher;
use starkprivacy_compliance::oracle::IComplianceOracleDispatcherTrait;

fn deploy_sanctions_oracle() -> ContractAddress {
    let contract = declare("SanctionsOracle").unwrap().contract_class();
    let owner: ContractAddress = starknet::get_contract_address();
    let calldata: Array<felt252> = array![owner.into()];
    let (address, _) = contract.deploy(@calldata).unwrap();
    address
}

// ─── SanctionsOracle Tests ──────────────────────────────────────

#[test]
fn test_sanctions_initial_state() {
    let address = deploy_sanctions_oracle();
    let oracle = ISanctionsOracleDispatcher { contract_address: address };

    let random_addr: ContractAddress = 0x1234.try_into().unwrap();
    assert!(!oracle.is_sanctioned(random_addr), "random address should not be sanctioned");
}

#[test]
fn test_sanctions_owner() {
    let address = deploy_sanctions_oracle();
    let oracle = ISanctionsOracleDispatcher { contract_address: address };

    let expected_owner = starknet::get_contract_address();
    assert!(oracle.get_owner() == expected_owner, "owner mismatch");
}

#[test]
fn test_add_sanctioned() {
    let address = deploy_sanctions_oracle();
    let oracle = ISanctionsOracleDispatcher { contract_address: address };

    let bad_actor: ContractAddress = 0xBAD.try_into().unwrap();

    assert!(!oracle.is_sanctioned(bad_actor), "should not be sanctioned initially");

    oracle.add_sanctioned(bad_actor);
    assert!(oracle.is_sanctioned(bad_actor), "should be sanctioned after add");
}

#[test]
fn test_remove_sanctioned() {
    let address = deploy_sanctions_oracle();
    let oracle = ISanctionsOracleDispatcher { contract_address: address };

    let addr: ContractAddress = 0xABC.try_into().unwrap();
    oracle.add_sanctioned(addr);
    assert!(oracle.is_sanctioned(addr), "should be sanctioned");

    oracle.remove_sanctioned(addr);
    assert!(!oracle.is_sanctioned(addr), "should be unsanctioned after removal");
}

#[test]
fn test_sanctions_multiple_addresses() {
    let address = deploy_sanctions_oracle();
    let oracle = ISanctionsOracleDispatcher { contract_address: address };

    let addr1: ContractAddress = 0x111.try_into().unwrap();
    let addr2: ContractAddress = 0x222.try_into().unwrap();
    let addr3: ContractAddress = 0x333.try_into().unwrap();

    oracle.add_sanctioned(addr1);
    oracle.add_sanctioned(addr2);

    assert!(oracle.is_sanctioned(addr1), "addr1 should be sanctioned");
    assert!(oracle.is_sanctioned(addr2), "addr2 should be sanctioned");
    assert!(!oracle.is_sanctioned(addr3), "addr3 should not be sanctioned");
}

// ─── ComplianceOracle Interface Tests ───────────────────────────

#[test]
fn test_compliance_check_deposit_allowed() {
    let address = deploy_sanctions_oracle();
    let compliance = IComplianceOracleDispatcher { contract_address: address };

    let depositor: ContractAddress = 0x100.try_into().unwrap();
    assert!(compliance.check_deposit(depositor, 1000, 0), "non-sanctioned depositor should pass");
}

#[test]
fn test_compliance_check_deposit_blocked() {
    let address = deploy_sanctions_oracle();
    let oracle = ISanctionsOracleDispatcher { contract_address: address };
    let compliance = IComplianceOracleDispatcher { contract_address: address };

    let sanctioned: ContractAddress = 0xBAD.try_into().unwrap();
    oracle.add_sanctioned(sanctioned);

    assert!(!compliance.check_deposit(sanctioned, 1000, 0), "sanctioned depositor should be blocked");
}

#[test]
fn test_compliance_check_withdrawal_allowed() {
    let address = deploy_sanctions_oracle();
    let compliance = IComplianceOracleDispatcher { contract_address: address };

    let recipient: ContractAddress = 0x200.try_into().unwrap();
    assert!(compliance.check_withdrawal(recipient, 500, 0), "non-sanctioned recipient should pass");
}

#[test]
fn test_compliance_check_withdrawal_blocked() {
    let address = deploy_sanctions_oracle();
    let oracle = ISanctionsOracleDispatcher { contract_address: address };
    let compliance = IComplianceOracleDispatcher { contract_address: address };

    let sanctioned: ContractAddress = 0xBAD.try_into().unwrap();
    oracle.add_sanctioned(sanctioned);

    assert!(
        !compliance.check_withdrawal(sanctioned, 500, 0),
        "sanctioned recipient should be blocked",
    );
}

#[test]
fn test_compliance_check_transfer_always_passes() {
    let address = deploy_sanctions_oracle();
    let compliance = IComplianceOracleDispatcher { contract_address: address };

    // Transfers are anonymized — only nullifiers and commitments visible
    let nullifiers: Span<felt252> = array![0xAF01, 0xAF02].span();
    let outputs: Span<felt252> = array![0xB001, 0xB002].span();
    assert!(compliance.check_transfer(nullifiers, outputs), "transfers should always pass compliance");
}
