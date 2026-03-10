/// EpochManager — cross-chain nullifier synchronization via epochs.
///
/// Ported from Lumora's EpochManager concept:
/// - Each epoch represents a time window for nullifier accumulation
/// - At epoch boundaries, a nullifier root is published for cross-chain verification
/// - Domain-separated nullifiers (chain_id, app_id) prevent cross-chain double-spend
///
/// The epoch root is a Poseidon hash of all nullifiers spent within that epoch,
/// enabling efficient cross-chain verification without transmitting individual nullifiers.

use starknet::ContractAddress;

#[starknet::interface]
pub trait IEpochManager<TContractState> {
    /// Start a new epoch. Finalizes the previous epoch's nullifier root.
    fn advance_epoch(ref self: TContractState);

    /// Record a nullifier in the current epoch's accumulator.
    fn record_nullifier(ref self: TContractState, nullifier: felt252);

    /// Get the current epoch number.
    fn get_current_epoch(self: @TContractState) -> u64;

    /// Get the nullifier root for a finalized epoch.
    fn get_epoch_root(self: @TContractState, epoch: u64) -> felt252;

    /// Get the number of nullifiers in the current epoch.
    fn get_current_epoch_count(self: @TContractState) -> u64;

    /// Check if a nullifier was recorded in a specific epoch.
    fn is_nullifier_in_epoch(self: @TContractState, epoch: u64, nullifier: felt252) -> bool;

    /// Get the chain ID for this epoch manager.
    fn get_chain_id(self: @TContractState) -> felt252;
}

#[starknet::contract]
pub mod EpochManager {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starkprivacy_primitives::hash::poseidon_hash_2;

    #[storage]
    struct Storage {
        /// Owner / authorized caller (typically the PrivacyPool or BridgeRouter).
        owner: ContractAddress,
        /// Chain ID for domain separation.
        chain_id: felt252,
        /// Current epoch number.
        current_epoch: u64,
        /// Running hash accumulator for current epoch: H(prev_accum, new_nullifier).
        current_accumulator: felt252,
        /// Number of nullifiers in current epoch.
        current_count: u64,
        /// Finalized epoch roots: epoch -> nullifier_root.
        epoch_roots: Map<u64, felt252>,
        /// Finalized epoch sizes: epoch -> count.
        epoch_sizes: Map<u64, u64>,
        /// Nullifier → epoch mapping for lookups.
        nullifier_epoch: Map<felt252, u64>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        EpochAdvanced: EpochAdvanced,
        NullifierRecorded: NullifierRecorded,
    }

    #[derive(Drop, starknet::Event)]
    struct EpochAdvanced {
        #[key]
        epoch: u64,
        nullifier_root: felt252,
        nullifier_count: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct NullifierRecorded {
        #[key]
        epoch: u64,
        nullifier: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, chain_id: felt252) {
        self.owner.write(owner);
        self.chain_id.write(chain_id);
        self.current_epoch.write(1); // Start at epoch 1
        self.current_accumulator.write(0);
        self.current_count.write(0);
    }

    #[abi(embed_v0)]
    impl EpochManagerImpl of super::IEpochManager<ContractState> {
        fn advance_epoch(ref self: ContractState) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");

            let epoch = self.current_epoch.read();
            let root = self.current_accumulator.read();
            let count = self.current_count.read();

            // Finalize current epoch
            self.epoch_roots.write(epoch, root);
            self.epoch_sizes.write(epoch, count);

            // Start new epoch
            self.current_epoch.write(epoch + 1);
            self.current_accumulator.write(0);
            self.current_count.write(0);

            self.emit(EpochAdvanced { epoch, nullifier_root: root, nullifier_count: count });
        }

        fn record_nullifier(ref self: ContractState, nullifier: felt252) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");
            assert!(nullifier != 0, "invalid nullifier");

            // Check not already recorded
            assert!(self.nullifier_epoch.read(nullifier) == 0, "already recorded");

            // Update accumulator: new_accum = Poseidon(old_accum, nullifier)
            let old_accum = self.current_accumulator.read();
            let new_accum = poseidon_hash_2(old_accum, nullifier);
            self.current_accumulator.write(new_accum);

            // Track
            let epoch = self.current_epoch.read();
            self.nullifier_epoch.write(nullifier, epoch);
            let count = self.current_count.read();
            self.current_count.write(count + 1);

            self.emit(NullifierRecorded { epoch, nullifier });
        }

        fn get_current_epoch(self: @ContractState) -> u64 {
            self.current_epoch.read()
        }

        fn get_epoch_root(self: @ContractState, epoch: u64) -> felt252 {
            self.epoch_roots.read(epoch)
        }

        fn get_current_epoch_count(self: @ContractState) -> u64 {
            self.current_count.read()
        }

        fn is_nullifier_in_epoch(
            self: @ContractState, epoch: u64, nullifier: felt252,
        ) -> bool {
            self.nullifier_epoch.read(nullifier) == epoch
        }

        fn get_chain_id(self: @ContractState) -> felt252 {
            self.chain_id.read()
        }
    }
}
