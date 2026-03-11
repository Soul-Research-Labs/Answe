/// KakarotAdapter — EVM-to-Cairo bridge adapter for Kakarot zkEVM.
///
/// Translates EVM-style calls from Solidity interfaces (IStarkPrivacyPool,
/// IStealthRegistry, IComplianceOracle) into native Cairo contract calls.
///
/// Address Translation:
/// - EVM uses 20-byte (uint160) addresses, Starknet uses felt252 (251-bit).
/// - Kakarot maps EVM addresses to Starknet contract addresses via its
///   address registry. This adapter accepts felt252 directly since
///   Kakarot handles the translation at the EVM-to-Cairo boundary.
///
/// Fee Translation:
/// - EVM `msg.value` is translated to the `amount` parameter.
/// - Kakarot handles native token (ETH) bridging between EVM and Cairo layers.
/// - An optional gas premium is added via `gas_price_factor` for L2 gas cost coverage.
use starknet::ContractAddress;

#[starknet::interface]
pub trait IKakarotAdapter<TContractState> {
    /// Deposit via EVM interface. Translates to PrivacyPool.deposit().
    fn evm_deposit(
        ref self: TContractState,
        commitment: felt252,
        amount: u256,
        asset_id: felt252,
    );

    /// Transfer via EVM interface. Translates to PrivacyPool.transfer().
    fn evm_transfer(
        ref self: TContractState,
        proof: Span<felt252>,
        merkle_root: felt252,
        nullifiers: (felt252, felt252),
        output_commitments: (felt252, felt252),
    );

    /// Withdraw via EVM interface. Translates to PrivacyPool.withdraw().
    fn evm_withdraw(
        ref self: TContractState,
        proof: Span<felt252>,
        merkle_root: felt252,
        nullifiers: (felt252, felt252),
        output_commitment: felt252,
        recipient: ContractAddress,
        amount: u256,
        asset_id: felt252,
    );

    // ─── View functions ──────────────────────────────────────────

    /// Get the current Merkle root from the underlying pool.
    fn get_root(self: @TContractState) -> felt252;

    /// Get the leaf count from the underlying pool.
    fn get_leaf_count(self: @TContractState) -> u64;

    /// Check if a nullifier has been spent.
    fn is_nullifier_spent(self: @TContractState, nullifier: felt252) -> bool;

    /// Check if a root is in the known-root history.
    fn is_known_root(self: @TContractState, root: felt252) -> bool;

    /// Get the pool balance for a specific asset.
    fn get_pool_balance(self: @TContractState, asset_id: felt252) -> u256;

    // ─── Admin ───────────────────────────────────────────────────

    /// Get the underlying pool address.
    fn get_pool(self: @TContractState) -> ContractAddress;

    /// Get the gas price factor used for fee estimation.
    fn get_gas_price_factor(self: @TContractState) -> u256;

    /// Update the gas price factor (admin only).
    fn set_gas_price_factor(ref self: TContractState, factor: u256);

    /// Pause the adapter (stops all EVM calls from routing).
    fn pause(ref self: TContractState);

    /// Unpause the adapter.
    fn unpause(ref self: TContractState);
}

#[starknet::contract]
pub mod KakarotAdapter {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starkprivacy_pool::pool::{IPrivacyPoolDispatcher, IPrivacyPoolDispatcherTrait};

    /// Default gas price factor: 1 (no premium). Set higher for gas cost coverage.
    const DEFAULT_GAS_PRICE_FACTOR: u256 = 1;

    #[storage]
    struct Storage {
        /// The underlying Starknet PrivacyPool contract.
        pool: ContractAddress,
        /// Owner / admin.
        owner: ContractAddress,
        /// Gas price factor for EVM fee translation (basis points, 10000 = 1x).
        gas_price_factor: u256,
        /// Pause flag.
        paused: bool,
        /// Total EVM operations routed through this adapter.
        total_ops: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        EvmDeposit: EvmDeposit,
        EvmTransfer: EvmTransfer,
        EvmWithdraw: EvmWithdraw,
        GasPriceFactorUpdated: GasPriceFactorUpdated,
    }

    #[derive(Drop, starknet::Event)]
    struct EvmDeposit {
        #[key]
        commitment: felt252,
        amount: u256,
        asset_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct EvmTransfer {
        #[key]
        nullifier_1: felt252,
        nullifier_2: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct EvmWithdraw {
        #[key]
        nullifier_1: felt252,
        recipient: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct GasPriceFactorUpdated {
        old_factor: u256,
        new_factor: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        pool: ContractAddress,
        owner: ContractAddress,
        gas_price_factor: u256,
    ) {
        assert!(gas_price_factor > 0, "gas price factor must be positive");
        self.pool.write(pool);
        self.owner.write(owner);
        self.gas_price_factor.write(gas_price_factor);
        self.paused.write(false);
        self.total_ops.write(0);
    }

    #[abi(embed_v0)]
    impl KakarotAdapterImpl of super::IKakarotAdapter<ContractState> {
        fn evm_deposit(
            ref self: ContractState,
            commitment: felt252,
            amount: u256,
            asset_id: felt252,
        ) {
            self._assert_not_paused();

            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.deposit(commitment, amount, asset_id);

            self.total_ops.write(self.total_ops.read() + 1);
            self.emit(EvmDeposit { commitment, amount, asset_id });
        }

        fn evm_transfer(
            ref self: ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nullifiers: (felt252, felt252),
            output_commitments: (felt252, felt252),
        ) {
            self._assert_not_paused();

            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.transfer(proof, merkle_root, nullifiers, output_commitments);

            let (nf1, nf2) = nullifiers;
            self.total_ops.write(self.total_ops.read() + 1);
            self.emit(EvmTransfer { nullifier_1: nf1, nullifier_2: nf2 });
        }

        fn evm_withdraw(
            ref self: ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nullifiers: (felt252, felt252),
            output_commitment: felt252,
            recipient: ContractAddress,
            amount: u256,
            asset_id: felt252,
        ) {
            self._assert_not_paused();

            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.withdraw(proof, merkle_root, nullifiers, output_commitment, recipient, amount, asset_id);

            let (nf1, _nf2) = nullifiers;
            self.total_ops.write(self.total_ops.read() + 1);
            self.emit(EvmWithdraw { nullifier_1: nf1, recipient, amount });
        }

        // ─── View functions ──────────────────────────────────────

        fn get_root(self: @ContractState) -> felt252 {
            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.get_root()
        }

        fn get_leaf_count(self: @ContractState) -> u64 {
            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.get_leaf_count()
        }

        fn is_nullifier_spent(self: @ContractState, nullifier: felt252) -> bool {
            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.is_nullifier_spent(nullifier)
        }

        fn is_known_root(self: @ContractState, root: felt252) -> bool {
            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.is_known_root(root)
        }

        fn get_pool_balance(self: @ContractState, asset_id: felt252) -> u256 {
            let pool = IPrivacyPoolDispatcher { contract_address: self.pool.read() };
            pool.get_pool_balance(asset_id)
        }

        // ─── Admin ───────────────────────────────────────────────

        fn get_pool(self: @ContractState) -> ContractAddress {
            self.pool.read()
        }

        fn get_gas_price_factor(self: @ContractState) -> u256 {
            self.gas_price_factor.read()
        }

        fn set_gas_price_factor(ref self: ContractState, factor: u256) {
            self._assert_owner();
            assert!(factor > 0, "gas price factor must be positive");
            let old = self.gas_price_factor.read();
            self.gas_price_factor.write(factor);
            self.emit(GasPriceFactorUpdated { old_factor: old, new_factor: factor });
        }

        fn pause(ref self: ContractState) {
            self._assert_owner();
            assert!(!self.paused.read(), "already paused");
            self.paused.write(true);
        }

        fn unpause(ref self: ContractState) {
            self._assert_owner();
            assert!(self.paused.read(), "not paused");
            self.paused.write(false);
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _assert_owner(self: @ContractState) {
            assert!(get_caller_address() == self.owner.read(), "caller is not owner");
        }

        fn _assert_not_paused(self: @ContractState) {
            assert!(!self.paused.read(), "adapter is paused");
        }
    }
}
