/// BridgeRouter — routes cross-chain privacy operations.
///
/// Implements ZAseon's ZK-Bound State Lock pattern for Starknet:
/// 1. Lock: Deposit a commitment with bridge metadata (destination chain, epoch)
/// 2. Relay: Bridge adapter carries commitment + proof to destination
/// 3. Unlock: Verify proof on destination and insert commitment into local tree
///
/// Uses domain-separated nullifiers (chain_id, app_id) from Lumora to prevent
/// cross-chain double-spend.
use starknet::ContractAddress;

#[starknet::interface]
pub trait IBridgeRouter<TContractState> {
    /// Lock a commitment for cross-chain transfer.
    /// The commitment will be bridged to `dest_chain_id` and unlocked there.
    fn lock_for_bridge(
        ref self: TContractState,
        commitment: felt252,
        dest_chain_id: felt252,
        proof: Span<felt252>,
        nullifiers: (felt252, felt252),
    );

    /// Unlock a bridged commitment. Called by the bridge relay after verifying the L1 message.
    fn unlock_from_bridge(
        ref self: TContractState,
        commitment: felt252,
        source_chain_id: felt252,
        source_epoch: u64,
        bridge_proof: Span<felt252>,
    );

    /// Publish an epoch root for cross-chain nullifier synchronization.
    fn publish_epoch_root(ref self: TContractState, epoch: u64, nullifier_root: felt252);

    /// Get the epoch root for a given epoch number.
    fn get_epoch_root(self: @TContractState, epoch: u64) -> felt252;

    /// Get the current epoch number.
    fn get_current_epoch(self: @TContractState) -> u64;

    /// Get the privacy pool address this router is connected to.
    fn get_pool(self: @TContractState) -> ContractAddress;
}

#[starknet::contract]
pub mod BridgeRouter {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        /// The privacy pool this bridge is connected to
        pool: ContractAddress,
        /// Owner / admin
        owner: ContractAddress,
        /// Authorized bridge relayers: relayer_address -> is_authorized
        authorized_relayers: Map<ContractAddress, bool>,
        /// Epoch roots: epoch_number -> nullifier_root
        epoch_roots: Map<u64, felt252>,
        /// Current epoch number
        current_epoch: u64,
        /// Pending bridge locks: commitment -> (dest_chain_id, locked)
        bridge_locks: Map<felt252, felt252>,
        /// Bridge lock count
        lock_count: u64,
        /// This chain's ID for domain separation
        chain_id: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BridgeLock: BridgeLock,
        BridgeUnlock: BridgeUnlock,
        EpochRootPublished: EpochRootPublished,
    }

    #[derive(Drop, starknet::Event)]
    struct BridgeLock {
        #[key]
        commitment: felt252,
        dest_chain_id: felt252,
        nullifier_1: felt252,
        nullifier_2: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct BridgeUnlock {
        #[key]
        commitment: felt252,
        source_chain_id: felt252,
        source_epoch: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct EpochRootPublished {
        #[key]
        epoch: u64,
        nullifier_root: felt252,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        pool: ContractAddress,
        owner: ContractAddress,
        chain_id: felt252,
    ) {
        self.pool.write(pool);
        self.owner.write(owner);
        self.chain_id.write(chain_id);
        self.current_epoch.write(0);
    }

    #[abi(embed_v0)]
    impl BridgeRouterImpl of super::IBridgeRouter<ContractState> {
        fn lock_for_bridge(
            ref self: ContractState,
            commitment: felt252,
            dest_chain_id: felt252,
            proof: Span<felt252>,
            nullifiers: (felt252, felt252),
        ) {
            assert!(commitment != 0, "invalid commitment");
            assert!(dest_chain_id != 0, "invalid destination chain");
            assert!(proof.len() > 0, "proof required");

            let (nf1, nf2) = nullifiers;
            assert!(nf1 != nf2, "duplicate nullifiers");

            // Store the bridge lock
            self.bridge_locks.write(commitment, dest_chain_id);
            self.lock_count.write(self.lock_count.read() + 1);

            // TODO: Send L1 message or inter-chain message with commitment
            // starknet::send_message_to_l1(l1_bridge_address, payload)

            self.emit(BridgeLock { commitment, dest_chain_id, nullifier_1: nf1, nullifier_2: nf2 });
        }

        fn unlock_from_bridge(
            ref self: ContractState,
            commitment: felt252,
            source_chain_id: felt252,
            source_epoch: u64,
            bridge_proof: Span<felt252>,
        ) {
            // Only authorized relayers can unlock
            let caller = get_caller_address();
            assert!(self.authorized_relayers.read(caller), "unauthorized relayer");
            assert!(commitment != 0, "invalid commitment");
            assert!(bridge_proof.len() > 0, "bridge proof required");

            // TODO: Verify bridge proof (L1 message verification or cross-chain proof)
            // TODO: Insert commitment into the local privacy pool's Merkle tree
            // IPrivacyPoolDispatcher { pool }.deposit(commitment, amount, asset_id)

            self.emit(BridgeUnlock { commitment, source_chain_id, source_epoch });
        }

        fn publish_epoch_root(ref self: ContractState, epoch: u64, nullifier_root: felt252) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");
            assert!(nullifier_root != 0, "invalid root");
            assert!(epoch == self.current_epoch.read() + 1, "epoch must be sequential");

            self.epoch_roots.write(epoch, nullifier_root);
            self.current_epoch.write(epoch);

            self.emit(EpochRootPublished { epoch, nullifier_root });
        }

        fn get_epoch_root(self: @ContractState, epoch: u64) -> felt252 {
            self.epoch_roots.read(epoch)
        }

        fn get_current_epoch(self: @ContractState) -> u64 {
            self.current_epoch.read()
        }

        fn get_pool(self: @ContractState) -> ContractAddress {
            self.pool.read()
        }
    }
}
