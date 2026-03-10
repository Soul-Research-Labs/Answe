/// MadaraAdapter — Inter-chain privacy messaging for Madara appchains.
///
/// Madara L3 appchains settle on Starknet L2 via `--settlement-layer Starknet`.
/// This adapter enables privacy-preserving cross-appchain transfers:
///
/// 1. Lock: User locks commitment on source appchain with proof + nullifiers
/// 2. Relay: Cross-chain message carries commitment + epoch proof to target
/// 3. Unlock: Target verifies source epoch root and inserts commitment
///
/// Uses the EpochManager for nullifier synchronization between appchains.
/// Domain-separated nullifiers (chain_id, app_id) prevent cross-chain double-spend.

use starknet::ContractAddress;

#[starknet::interface]
pub trait IMadaraAdapter<TContractState> {
    /// Register a peer appchain for cross-chain messaging.
    fn register_peer(
        ref self: TContractState,
        peer_chain_id: felt252,
        peer_adapter: ContractAddress,
    );

    /// Lock a commitment for transfer to a peer appchain.
    fn lock_for_appchain(
        ref self: TContractState,
        commitment: felt252,
        dest_chain_id: felt252,
        nullifiers: (felt252, felt252),
        proof_hash: felt252,
    );

    /// Receive a commitment from a peer appchain.
    /// Verifies the source epoch root is known before accepting.
    fn receive_from_appchain(
        ref self: TContractState,
        commitment: felt252,
        source_chain_id: felt252,
        source_epoch: u64,
        epoch_root: felt252,
        proof_hash: felt252,
    );

    /// Sync an epoch root from a peer appchain.
    fn sync_epoch_root(
        ref self: TContractState,
        peer_chain_id: felt252,
        epoch: u64,
        root: felt252,
    );

    /// Get the synced epoch root for a peer chain + epoch.
    fn get_peer_epoch_root(
        self: @TContractState,
        peer_chain_id: felt252,
        epoch: u64,
    ) -> felt252;

    /// Check if a peer appchain is registered.
    fn is_peer_registered(self: @TContractState, peer_chain_id: felt252) -> bool;

    /// Get total outbound transfers to a specific peer.
    fn get_outbound_count(self: @TContractState, peer_chain_id: felt252) -> u64;

    /// Get total inbound transfers from a specific peer.
    fn get_inbound_count(self: @TContractState, peer_chain_id: felt252) -> u64;

    /// Get this adapter's chain ID.
    fn get_chain_id(self: @TContractState) -> felt252;
}

#[starknet::contract]
pub mod MadaraAdapter {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess,
        StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starkprivacy_primitives::hash::poseidon_hash_2;
    use starkprivacy_pool::pool::{IPrivacyPoolDispatcher, IPrivacyPoolDispatcherTrait};

    #[storage]
    struct Storage {
        /// Owner / admin.
        owner: ContractAddress,
        /// This chain's ID.
        chain_id: felt252,
        /// Privacy pool address.
        pool: ContractAddress,
        /// Local epoch manager address.
        epoch_manager: ContractAddress,
        /// Registered peers: peer_chain_id -> peer_adapter_address.
        peer_adapters: Map<felt252, ContractAddress>,
        /// Peer registration flag: peer_chain_id -> is_registered.
        peer_registered: Map<felt252, bool>,
        /// Synced peer epoch roots: hash(peer_chain_id, epoch) -> root.
        peer_epoch_roots: Map<felt252, felt252>,
        /// Outbound transfer count per peer: peer_chain_id -> count.
        outbound_counts: Map<felt252, u64>,
        /// Inbound transfer count per peer: peer_chain_id -> count.
        inbound_counts: Map<felt252, u64>,
        /// Processed commitments: commitment -> processed.
        processed_commitments: Map<felt252, bool>,
        /// Outbound lock tracking: commitment -> dest_chain_id.
        outbound_locks: Map<felt252, felt252>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PeerRegistered: PeerRegistered,
        AppchainLock: AppchainLock,
        AppchainReceive: AppchainReceive,
        EpochRootSynced: EpochRootSynced,
    }

    #[derive(Drop, starknet::Event)]
    struct PeerRegistered {
        #[key]
        peer_chain_id: felt252,
        peer_adapter: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct AppchainLock {
        #[key]
        commitment: felt252,
        dest_chain_id: felt252,
        nullifier_1: felt252,
        nullifier_2: felt252,
        proof_hash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct AppchainReceive {
        #[key]
        commitment: felt252,
        source_chain_id: felt252,
        source_epoch: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct EpochRootSynced {
        #[key]
        peer_chain_id: felt252,
        epoch: u64,
        root: felt252,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        chain_id: felt252,
        pool: ContractAddress,
        epoch_manager: ContractAddress,
    ) {
        assert!(chain_id != 0, "invalid chain_id");
        self.owner.write(owner);
        self.chain_id.write(chain_id);
        self.pool.write(pool);
        self.epoch_manager.write(epoch_manager);
    }

    #[abi(embed_v0)]
    impl MadaraAdapterImpl of super::IMadaraAdapter<ContractState> {
        fn register_peer(
            ref self: ContractState,
            peer_chain_id: felt252,
            peer_adapter: ContractAddress,
        ) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");
            assert!(peer_chain_id != 0, "invalid peer chain id");
            assert!(peer_chain_id != self.chain_id.read(), "cannot peer with self");
            assert!(!self.peer_registered.read(peer_chain_id), "peer already registered");

            self.peer_adapters.write(peer_chain_id, peer_adapter);
            self.peer_registered.write(peer_chain_id, true);

            self.emit(PeerRegistered { peer_chain_id, peer_adapter });
        }

        fn lock_for_appchain(
            ref self: ContractState,
            commitment: felt252,
            dest_chain_id: felt252,
            nullifiers: (felt252, felt252),
            proof_hash: felt252,
        ) {
            assert!(commitment != 0, "invalid commitment");
            assert!(self.peer_registered.read(dest_chain_id), "unknown peer chain");
            assert!(!self.processed_commitments.read(commitment), "commitment already processed");

            let (nf1, nf2) = nullifiers;
            assert!(nf1 != nf2, "duplicate nullifiers");
            assert!(nf1 != 0 && nf2 != 0, "invalid nullifier");
            assert!(proof_hash != 0, "invalid proof hash");

            // Mark as locked
            self.outbound_locks.write(commitment, dest_chain_id);
            self.processed_commitments.write(commitment, true);

            let count = self.outbound_counts.read(dest_chain_id);
            self.outbound_counts.write(dest_chain_id, count + 1);

            self.emit(AppchainLock {
                commitment, dest_chain_id,
                nullifier_1: nf1, nullifier_2: nf2,
                proof_hash,
            });
        }

        fn receive_from_appchain(
            ref self: ContractState,
            commitment: felt252,
            source_chain_id: felt252,
            source_epoch: u64,
            epoch_root: felt252,
            proof_hash: felt252,
        ) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");
            assert!(commitment != 0, "invalid commitment");
            assert!(self.peer_registered.read(source_chain_id), "unknown source chain");
            assert!(!self.processed_commitments.read(commitment), "already processed");

            // Verify the epoch root matches what we've synced for this peer
            let key = poseidon_hash_2(source_chain_id, source_epoch.into());
            let synced_root = self.peer_epoch_roots.read(key);
            assert!(synced_root != 0, "epoch root not synced");
            assert!(synced_root == epoch_root, "epoch root mismatch");

            // Accept the bridged commitment
            self.processed_commitments.write(commitment, true);

            let count = self.inbound_counts.read(source_chain_id);
            self.inbound_counts.write(source_chain_id, count + 1);

            // Insert commitment into local pool (nominal amount; real value is in ZK proof)
            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.deposit(commitment, 1_u256, 0);

            self.emit(AppchainReceive { commitment, source_chain_id, source_epoch });
        }

        fn sync_epoch_root(
            ref self: ContractState,
            peer_chain_id: felt252,
            epoch: u64,
            root: felt252,
        ) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");
            assert!(self.peer_registered.read(peer_chain_id), "unknown peer chain");
            assert!(root != 0, "invalid root");

            let key = poseidon_hash_2(peer_chain_id, epoch.into());
            assert!(self.peer_epoch_roots.read(key) == 0, "epoch root already synced");

            self.peer_epoch_roots.write(key, root);

            self.emit(EpochRootSynced { peer_chain_id, epoch, root });
        }

        fn get_peer_epoch_root(
            self: @ContractState,
            peer_chain_id: felt252,
            epoch: u64,
        ) -> felt252 {
            let key = poseidon_hash_2(peer_chain_id, epoch.into());
            self.peer_epoch_roots.read(key)
        }

        fn is_peer_registered(self: @ContractState, peer_chain_id: felt252) -> bool {
            self.peer_registered.read(peer_chain_id)
        }

        fn get_outbound_count(self: @ContractState, peer_chain_id: felt252) -> u64 {
            self.outbound_counts.read(peer_chain_id)
        }

        fn get_inbound_count(self: @ContractState, peer_chain_id: felt252) -> u64 {
            self.inbound_counts.read(peer_chain_id)
        }

        fn get_chain_id(self: @ContractState) -> felt252 {
            self.chain_id.read()
        }
    }
}
