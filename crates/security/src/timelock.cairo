/// Timelock — delayed execution governance for admin operations.
///
/// All critical admin operations (oracle updates, rate limit changes,
/// peer registration) must be queued with a minimum delay before execution.
/// This gives the community time to review proposed changes.

use starknet::ContractAddress;

#[starknet::interface]
pub trait ITimelock<TContractState> {
    /// Queue a new operation (only proposer).
    fn queue(
        ref self: TContractState,
        target: ContractAddress,
        selector: felt252,
        calldata_hash: felt252,
        delay: u64,
    ) -> felt252;

    /// Execute a queued operation by making the actual cross-contract call.
    /// Caller must provide the calldata matching the stored calldata_hash.
    fn execute(ref self: TContractState, operation_id: felt252, calldata: Span<felt252>);

    /// Cancel a queued operation (only proposer).
    fn cancel(ref self: TContractState, operation_id: felt252);

    /// Get minimum delay in seconds.
    fn get_min_delay(self: @TContractState) -> u64;

    /// Check whether an operation is ready to execute.
    fn is_ready(self: @TContractState, operation_id: felt252) -> bool;

    /// Check whether an operation is pending.
    fn is_pending(self: @TContractState, operation_id: felt252) -> bool;

    /// Get operation timestamp (0 = not queued).
    fn get_operation_timestamp(self: @TContractState, operation_id: felt252) -> u64;

    /// Get the proposer address.
    fn get_proposer(self: @TContractState) -> ContractAddress;

    /// Update minimum delay (only via timelock itself).
    fn update_min_delay(ref self: TContractState, new_delay: u64);
}

#[starknet::contract]
pub mod Timelock {
    use core::poseidon::poseidon_hash_span;
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, SyscallResultTrait};
    use starknet::syscalls::call_contract_syscall;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    const STATUS_EMPTY: u8 = 0;
    const STATUS_PENDING: u8 = 1;
    const STATUS_EXECUTED: u8 = 2;
    const STATUS_CANCELLED: u8 = 3;

    #[storage]
    struct Storage {
        proposer: ContractAddress,
        min_delay: u64,
        /// operation_id -> execution timestamp (when it becomes executable)
        timestamps: Map<felt252, u64>,
        /// operation_id -> status
        status: Map<felt252, u8>,
        /// operation_id -> target
        targets: Map<felt252, ContractAddress>,
        /// operation_id -> selector
        selectors: Map<felt252, felt252>,
        /// operation_id -> calldata_hash
        calldata_hashes: Map<felt252, felt252>,
        /// Incrementing nonce for unique operation IDs
        nonce: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        OperationQueued: OperationQueued,
        OperationExecuted: OperationExecuted,
        OperationCancelled: OperationCancelled,
        MinDelayUpdated: MinDelayUpdated,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OperationQueued {
        #[key]
        pub operation_id: felt252,
        pub target: ContractAddress,
        pub selector: felt252,
        pub execute_after: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OperationExecuted {
        #[key]
        pub operation_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OperationCancelled {
        #[key]
        pub operation_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MinDelayUpdated {
        pub old_delay: u64,
        pub new_delay: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, proposer: ContractAddress, min_delay: u64) {
        assert!(min_delay > 0, "min delay must be positive");
        self.proposer.write(proposer);
        self.min_delay.write(min_delay);
        self.nonce.write(0);
    }

    #[abi(embed_v0)]
    impl TimelockImpl of super::ITimelock<ContractState> {
        fn queue(
            ref self: ContractState,
            target: ContractAddress,
            selector: felt252,
            calldata_hash: felt252,
            delay: u64,
        ) -> felt252 {
            let caller = get_caller_address();
            assert!(caller == self.proposer.read(), "only proposer can queue");
            assert!(delay >= self.min_delay.read(), "delay below minimum");

            let nonce = self.nonce.read();
            self.nonce.write(nonce + 1);

            // Compute operation ID from contents + nonce
            let op_id = poseidon_hash_span(
                array![target.into(), selector, calldata_hash, nonce.into()].span(),
            );

            assert!(self.status.read(op_id) == STATUS_EMPTY, "operation already exists");

            let now = get_block_timestamp();
            let execute_after = now + delay;

            self.timestamps.write(op_id, execute_after);
            self.status.write(op_id, STATUS_PENDING);
            self.targets.write(op_id, target);
            self.selectors.write(op_id, selector);
            self.calldata_hashes.write(op_id, calldata_hash);

            self
                .emit(
                    OperationQueued {
                        operation_id: op_id, target, selector, execute_after,
                    },
                );

            op_id
        }

        fn execute(ref self: ContractState, operation_id: felt252, calldata: Span<felt252>) {
            assert!(self.status.read(operation_id) == STATUS_PENDING, "not pending");

            let now = get_block_timestamp();
            let execute_after = self.timestamps.read(operation_id);
            assert!(now >= execute_after, "too early");

            // Verify calldata matches stored hash
            let stored_hash = self.calldata_hashes.read(operation_id);
            let provided_hash = poseidon_hash_span(calldata);
            assert!(stored_hash == provided_hash, "calldata hash mismatch");

            self.status.write(operation_id, STATUS_EXECUTED);

            // Make the actual cross-contract call
            let target = self.targets.read(operation_id);
            let selector = self.selectors.read(operation_id);
            call_contract_syscall(target, selector, calldata).unwrap_syscall();

            self.emit(OperationExecuted { operation_id });
        }

        fn cancel(ref self: ContractState, operation_id: felt252) {
            let caller = get_caller_address();
            assert!(caller == self.proposer.read(), "only proposer can cancel");
            assert!(self.status.read(operation_id) == STATUS_PENDING, "not pending");

            self.status.write(operation_id, STATUS_CANCELLED);

            self.emit(OperationCancelled { operation_id });
        }

        fn get_min_delay(self: @ContractState) -> u64 {
            self.min_delay.read()
        }

        fn is_ready(self: @ContractState, operation_id: felt252) -> bool {
            if self.status.read(operation_id) != STATUS_PENDING {
                return false;
            }
            let now = get_block_timestamp();
            now >= self.timestamps.read(operation_id)
        }

        fn is_pending(self: @ContractState, operation_id: felt252) -> bool {
            self.status.read(operation_id) == STATUS_PENDING
        }

        fn get_operation_timestamp(self: @ContractState, operation_id: felt252) -> u64 {
            self.timestamps.read(operation_id)
        }

        fn get_proposer(self: @ContractState) -> ContractAddress {
            self.proposer.read()
        }

        fn update_min_delay(ref self: ContractState, new_delay: u64) {
            let caller = get_caller_address();
            assert!(caller == self.proposer.read(), "only proposer");
            assert!(new_delay > 0, "delay must be positive");

            let old_delay = self.min_delay.read();
            self.min_delay.write(new_delay);

            self.emit(MinDelayUpdated { old_delay, new_delay });
        }
    }
}
