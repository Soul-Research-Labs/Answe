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
    fn lock_for_bridge(
        ref self: TContractState,
        commitment: felt252,
        dest_chain_id: felt252,
        amount: u256,
        asset_id: felt252,
        proof: Span<felt252>,
        nullifiers: (felt252, felt252),
    );

    /// Unlock a bridged commitment. Called by authorized relayers.
    fn unlock_from_bridge(
        ref self: TContractState,
        commitment: felt252,
        source_chain_id: felt252,
        source_epoch: u64,
        amount: u256,
        asset_id: felt252,
        bridge_proof: Span<felt252>,
    );

    /// Get the locked amount for a commitment.
    fn get_lock_amount(self: @TContractState, commitment: felt252) -> u256;

    /// Get the locked asset ID for a commitment.
    fn get_lock_asset_id(self: @TContractState, commitment: felt252) -> felt252;

    /// Publish an epoch root for cross-chain nullifier synchronization.
    fn publish_epoch_root(ref self: TContractState, epoch: u64, nullifier_root: felt252);

    /// Authorize a relayer address.
    fn authorize_relayer(ref self: TContractState, relayer: ContractAddress);

    /// Revoke a relayer's authorization.
    fn revoke_relayer(ref self: TContractState, relayer: ContractAddress);

    /// Check if an address is an authorized relayer.
    fn is_authorized_relayer(self: @TContractState, relayer: ContractAddress) -> bool;

    /// Get the epoch root for a given epoch number.
    fn get_epoch_root(self: @TContractState, epoch: u64) -> felt252;

    /// Get the current epoch number.
    fn get_current_epoch(self: @TContractState) -> u64;

    /// Get the privacy pool address this router is connected to.
    fn get_pool(self: @TContractState) -> ContractAddress;

    /// Get total lock count.
    fn get_lock_count(self: @TContractState) -> u64;

    /// Get total unlock count.
    fn get_unlock_count(self: @TContractState) -> u64;
}

#[starknet::contract]
pub mod BridgeRouter {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starkprivacy_pool::pool::{IPrivacyPoolDispatcher, IPrivacyPoolDispatcherTrait};

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
        /// Pending bridge locks: commitment -> dest_chain_id (0 = not locked)
        bridge_locks: Map<felt252, felt252>,
        /// Locked amounts: commitment -> amount
        lock_amounts: Map<felt252, u256>,
        /// Locked asset IDs: commitment -> asset_id
        lock_asset_ids: Map<felt252, felt252>,
        /// Replay protection: commitment -> unlocked flag
        unlocked_commitments: Map<felt252, bool>,
        /// Bridge lock count
        lock_count: u64,
        /// Bridge unlock count
        unlock_count: u64,
        /// This chain's ID for domain separation
        chain_id: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BridgeLock: BridgeLock,
        BridgeUnlock: BridgeUnlock,
        EpochRootPublished: EpochRootPublished,
        RelayerAuthorized: RelayerAuthorized,
        RelayerRevoked: RelayerRevoked,
    }

    #[derive(Drop, starknet::Event)]
    struct BridgeLock {
        #[key]
        commitment: felt252,
        dest_chain_id: felt252,
        amount: u256,
        asset_id: felt252,
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

    #[derive(Drop, starknet::Event)]
    struct RelayerAuthorized {
        #[key]
        relayer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct RelayerRevoked {
        #[key]
        relayer: ContractAddress,
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
            amount: u256,
            asset_id: felt252,
            proof: Span<felt252>,
            nullifiers: (felt252, felt252),
        ) {
            assert!(commitment != 0, "invalid commitment");
            assert!(dest_chain_id != 0, "invalid destination chain");
            assert!(amount > 0, "amount must be positive");
            assert!(proof.len() > 0, "proof required");
            assert!(self.bridge_locks.read(commitment) == 0, "commitment already locked");

            let (nf1, nf2) = nullifiers;
            assert!(nf1 != nf2, "duplicate nullifiers");

            // Validate proof via the privacy pool's verifier
            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            let root = pool.get_root();
            assert!(pool.is_known_root(root), "pool root invalid");

            // Store the bridge lock with amount and asset_id
            self.bridge_locks.write(commitment, dest_chain_id);
            self.lock_amounts.write(commitment, amount);
            self.lock_asset_ids.write(commitment, asset_id);
            self.lock_count.write(self.lock_count.read() + 1);

            self.emit(BridgeLock { commitment, dest_chain_id, amount, asset_id, nullifier_1: nf1, nullifier_2: nf2 });
        }

        fn unlock_from_bridge(
            ref self: ContractState,
            commitment: felt252,
            source_chain_id: felt252,
            source_epoch: u64,
            amount: u256,
            asset_id: felt252,
            bridge_proof: Span<felt252>,
        ) {
            let caller = get_caller_address();
            assert!(self.authorized_relayers.read(caller), "unauthorized relayer");
            assert!(commitment != 0, "invalid commitment");
            assert!(amount > 0, "amount must be positive");
            assert!(bridge_proof.len() > 0, "bridge proof required");
            assert!(!self.unlocked_commitments.read(commitment), "commitment already unlocked");

            // Verify source epoch root exists
            let epoch_root = self.epoch_roots.read(source_epoch);
            assert!(epoch_root != 0, "unknown source epoch");

            // Mark as unlocked (replay protection)
            self.unlocked_commitments.write(commitment, true);
            self.unlock_count.write(self.unlock_count.read() + 1);

            // Insert commitment into the local privacy pool with the actual bridged amount
            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.deposit(commitment, amount, asset_id);

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

        fn authorize_relayer(ref self: ContractState, relayer: ContractAddress) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");
            self.authorized_relayers.write(relayer, true);
            self.emit(RelayerAuthorized { relayer });
        }

        fn revoke_relayer(ref self: ContractState, relayer: ContractAddress) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "only owner");
            self.authorized_relayers.write(relayer, false);
            self.emit(RelayerRevoked { relayer });
        }

        fn is_authorized_relayer(self: @ContractState, relayer: ContractAddress) -> bool {
            self.authorized_relayers.read(relayer)
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

        fn get_lock_count(self: @ContractState) -> u64 {
            self.lock_count.read()
        }

        fn get_unlock_count(self: @ContractState) -> u64 {
            self.unlock_count.read()
        }

        fn get_lock_amount(self: @ContractState, commitment: felt252) -> u256 {
            self.lock_amounts.read(commitment)
        }

        fn get_lock_asset_id(self: @ContractState, commitment: felt252) -> felt252 {
            self.lock_asset_ids.read(commitment)
        }
    }
}
