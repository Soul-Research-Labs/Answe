/// SanctionsOracle — concrete compliance implementation with a sanctions list.
///
/// Maintains an on-chain allowlist/blocklist of addresses.
/// The privacy pool calls check_deposit/check_withdrawal before processing.

use starknet::ContractAddress;

#[starknet::interface]
pub trait ISanctionsOracle<TContractState> {
    /// Add an address to the sanctions list.
    fn add_sanctioned(ref self: TContractState, address: ContractAddress);

    /// Remove an address from the sanctions list.
    fn remove_sanctioned(ref self: TContractState, address: ContractAddress);

    /// Check if an address is sanctioned.
    fn is_sanctioned(self: @TContractState, address: ContractAddress) -> bool;

    /// Get the owner of this oracle.
    fn get_owner(self: @TContractState) -> ContractAddress;
}

#[starknet::contract]
pub mod SanctionsOracle {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    #[storage]
    struct Storage {
        owner: ContractAddress,
        sanctioned: Map<ContractAddress, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        AddressSanctioned: AddressSanctioned,
        AddressUnsanctioned: AddressUnsanctioned,
    }

    #[derive(Drop, starknet::Event)]
    struct AddressSanctioned {
        #[key]
        address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct AddressUnsanctioned {
        #[key]
        address: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
    }

    // Implement the IComplianceOracle interface
    #[abi(embed_v0)]
    impl ComplianceImpl of super::super::oracle::IComplianceOracle<ContractState> {
        fn check_deposit(
            self: @ContractState,
            depositor: ContractAddress,
            amount: u256,
            asset_id: felt252,
        ) -> bool {
            !self.sanctioned.read(depositor)
        }

        fn check_withdrawal(
            self: @ContractState,
            recipient: ContractAddress,
            amount: u256,
            asset_id: felt252,
        ) -> bool {
            !self.sanctioned.read(recipient)
        }

        fn check_transfer(
            self: @ContractState,
            nullifiers: Span<felt252>,
            output_commitments: Span<felt252>,
        ) -> bool {
            // Transfers are private — no address to check.
            // Return true (allowed) unless additional policy rules apply.
            true
        }
    }

    #[abi(embed_v0)]
    impl SanctionsOracleImpl of super::ISanctionsOracle<ContractState> {
        fn add_sanctioned(ref self: ContractState, address: ContractAddress) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");
            self.sanctioned.write(address, true);
            self.emit(AddressSanctioned { address });
        }

        fn remove_sanctioned(ref self: ContractState, address: ContractAddress) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");
            self.sanctioned.write(address, false);
            self.emit(AddressUnsanctioned { address });
        }

        fn is_sanctioned(self: @ContractState, address: ContractAddress) -> bool {
            self.sanctioned.read(address)
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }
    }
}
