/// NullifierRegistry — stores and validates spent nullifiers.
///
/// Each nullifier can only be marked as spent once. The registry is used by
/// the PrivacyPool to prevent double-spend of notes.
use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};

#[starknet::interface]
pub trait INullifierRegistry<TContractState> {
    /// Check if a nullifier has been spent.
    fn is_spent(self: @TContractState, nullifier: felt252) -> bool;

    /// Mark a nullifier as spent. Can only be called by the authorized pool contract.
    fn mark_spent(ref self: TContractState, nullifier: felt252);

    /// Batch check: returns true only if ALL nullifiers are unspent.
    fn are_all_unspent(self: @TContractState, nullifiers: Span<felt252>) -> bool;

    /// Get the pool address authorized to mark nullifiers.
    fn get_pool(self: @TContractState) -> starknet::ContractAddress;
}

#[starknet::contract]
pub mod NullifierRegistry {
    use starknet::ContractAddress;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::get_caller_address;

    #[storage]
    struct Storage {
        /// Mapping: nullifier -> is_spent (0 = unspent, 1 = spent)
        spent: Map<felt252, bool>,
        /// The PrivacyPool contract authorized to mark nullifiers.
        pool: ContractAddress,
        /// Total count of spent nullifiers (for metrics).
        spent_count: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        NullifierSpent: NullifierSpent,
    }

    #[derive(Drop, starknet::Event)]
    struct NullifierSpent {
        #[key]
        nullifier: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, pool: ContractAddress) {
        self.pool.write(pool);
    }

    #[abi(embed_v0)]
    impl NullifierRegistryImpl of super::INullifierRegistry<ContractState> {
        fn is_spent(self: @ContractState, nullifier: felt252) -> bool {
            self.spent.read(nullifier)
        }

        fn mark_spent(ref self: ContractState, nullifier: felt252) {
            // Only the pool can mark nullifiers as spent
            let caller = get_caller_address();
            assert!(caller == self.pool.read(), "only pool can mark spent");
            assert!(!self.spent.read(nullifier), "nullifier already spent");

            self.spent.write(nullifier, true);
            self.spent_count.write(self.spent_count.read() + 1);
            self.emit(NullifierSpent { nullifier });
        }

        fn are_all_unspent(self: @ContractState, nullifiers: Span<felt252>) -> bool {
            let mut i: u32 = 0;
            let mut all_unspent = true;
            while i < nullifiers.len() {
                if self.spent.read(*nullifiers.at(i)) {
                    all_unspent = false;
                    break;
                }
                i += 1;
            };
            all_unspent
        }

        fn get_pool(self: @ContractState) -> ContractAddress {
            self.pool.read()
        }
    }
}
