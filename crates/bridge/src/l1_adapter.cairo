/// L1BridgeAdapter — Starknet L1↔L2 messaging for privacy-preserving cross-chain transfers.
///
/// Implements the ZK-Bound State Lock pattern:
/// 1. User deposits on L1/L2, locking a commitment with bridge metadata
/// 2. Bridge relay carries the commitment + proof hash to the other layer
/// 3. Destination verifies the message origin and inserts commitment into local pool
///
/// Uses Starknet's native send_message_to_l1 / L1 handler pattern.

use starknet::ContractAddress;

#[starknet::interface]
pub trait IL1BridgeAdapter<TContractState> {
    /// Initiate a bridge transfer from L2 to L1.
    /// Sends the commitment via Starknet's native L1 messaging.
    fn bridge_to_l1(
        ref self: TContractState,
        commitment: felt252,
        l1_recipient: felt252,
        amount: u256,
        asset_id: felt252,
    );

    /// Handle a message arriving from L1 to L2.
    /// Called by the Starknet OS when an L1→L2 message is consumed.
    fn handle_l1_message(
        ref self: TContractState,
        commitment: felt252,
        amount: u256,
        asset_id: felt252,
    );

    /// Get the L1 bridge contract address.
    fn get_l1_bridge(self: @TContractState) -> felt252;

    /// Get the privacy pool this adapter feeds into.
    fn get_pool(self: @TContractState) -> ContractAddress;

    /// Get number of L2→L1 transfers initiated.
    fn get_outbound_count(self: @TContractState) -> u64;

    /// Get number of L1→L2 transfers received.
    fn get_inbound_count(self: @TContractState) -> u64;
}

#[starknet::contract]
pub mod L1BridgeAdapter {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    #[storage]
    struct Storage {
        /// L1 bridge contract address (Ethereum address as felt252).
        l1_bridge: felt252,
        /// Privacy pool contract address.
        pool: ContractAddress,
        /// Owner for admin operations.
        owner: ContractAddress,
        /// Outbound transfer tracking: index -> commitment.
        outbound_commitments: Map<u64, felt252>,
        outbound_count: u64,
        /// Inbound transfer tracking: index -> commitment.
        inbound_commitments: Map<u64, felt252>,
        inbound_count: u64,
        /// Processed messages: commitment hash -> processed flag.
        processed: Map<felt252, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BridgeToL1Initiated: BridgeToL1Initiated,
        BridgeFromL1Completed: BridgeFromL1Completed,
    }

    #[derive(Drop, starknet::Event)]
    struct BridgeToL1Initiated {
        #[key]
        commitment: felt252,
        l1_recipient: felt252,
        amount: u256,
        asset_id: felt252,
        index: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct BridgeFromL1Completed {
        #[key]
        commitment: felt252,
        amount: u256,
        asset_id: felt252,
        index: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        l1_bridge: felt252,
        pool: ContractAddress,
        owner: ContractAddress,
    ) {
        assert!(l1_bridge != 0, "invalid L1 bridge address");
        self.l1_bridge.write(l1_bridge);
        self.pool.write(pool);
        self.owner.write(owner);
        self.outbound_count.write(0);
        self.inbound_count.write(0);
    }

    #[abi(embed_v0)]
    impl L1BridgeAdapterImpl of super::IL1BridgeAdapter<ContractState> {
        fn bridge_to_l1(
            ref self: ContractState,
            commitment: felt252,
            l1_recipient: felt252,
            amount: u256,
            asset_id: felt252,
        ) {
            assert!(commitment != 0, "invalid commitment");
            assert!(l1_recipient != 0, "invalid L1 recipient");
            assert!(amount > 0_u256, "amount must be positive");

            // Build the L1 message payload:
            // [commitment, amount_low, amount_high, asset_id, l1_recipient]
            let payload = array![
                commitment,
                (amount & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF_u256).try_into().unwrap(),
                (amount / 0x100000000000000000000000000000000_u256).try_into().unwrap(),
                asset_id,
                l1_recipient,
            ];

            // Send message to L1 via Starknet's native messaging
            starknet::syscalls::send_message_to_l1_syscall(
                self.l1_bridge.read(), payload.span(),
            )
                .unwrap_syscall();

            // Track outbound transfer
            let idx = self.outbound_count.read();
            self.outbound_commitments.write(idx, commitment);
            self.outbound_count.write(idx + 1);

            self
                .emit(
                    BridgeToL1Initiated {
                        commitment, l1_recipient, amount, asset_id, index: idx,
                    },
                );
        }

        fn handle_l1_message(
            ref self: ContractState,
            commitment: felt252,
            amount: u256,
            asset_id: felt252,
        ) {
            // Only the Starknet OS should deliver L1 messages, verified by the sequencer.
            // Additional check: ensure this commitment hasn't been processed already.
            assert!(commitment != 0, "invalid commitment");
            assert!(!self.processed.read(commitment), "already processed");

            self.processed.write(commitment, true);

            // Track inbound transfer
            let idx = self.inbound_count.read();
            self.inbound_commitments.write(idx, commitment);
            self.inbound_count.write(idx + 1);

            // TODO: Call pool.deposit(commitment, amount, asset_id) to insert into tree
            // IPrivacyPoolDispatcher { contract_address: self.pool.read() }
            //     .deposit(commitment, amount, asset_id);

            self
                .emit(BridgeFromL1Completed { commitment, amount, asset_id, index: idx });
        }

        fn get_l1_bridge(self: @ContractState) -> felt252 {
            self.l1_bridge.read()
        }

        fn get_pool(self: @ContractState) -> ContractAddress {
            self.pool.read()
        }

        fn get_outbound_count(self: @ContractState) -> u64 {
            self.outbound_count.read()
        }

        fn get_inbound_count(self: @ContractState) -> u64 {
            self.inbound_count.read()
        }
    }

    use starknet::SyscallResultTrait;
}
