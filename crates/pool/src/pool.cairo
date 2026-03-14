/// PrivacyPool — main Starknet contract for shielded deposits, transfers, and withdrawals.
///
/// Architecture ported from Lumora's PrivacyPool + ZAseon's compliance hooks.
///
/// Flow:
/// 1. deposit(commitment, amount) — user deposits tokens, commitment added to Merkle tree
/// 2. transfer(proof, nullifiers, new_commitments, root) — private 2-in-2-out transfer
/// 3. withdraw(proof, nullifiers, root, recipient, amount) — exit funds back to a public address
///
/// The Merkle tree and nullifier registry are embedded in this contract.
/// Compliance oracle is optional (zero address = no compliance checks).
/// Proof verification is performed by an external IProofVerifier contract.
use starknet::ContractAddress;
use crate::proof_verifier::{IProofVerifierDispatcher, IProofVerifierDispatcherTrait};

#[starknet::interface]
pub trait IPrivacyPool<TContractState> {
    /// Deposit tokens into the privacy pool. The commitment is added to the Merkle tree.
    /// The caller must have approved the pool to spend `amount` of the given token.
    fn deposit(ref self: TContractState, commitment: felt252, amount: u256, asset_id: felt252);

    /// Execute a private transfer (2-in-2-out). Spends two input notes and creates two output notes.
    /// The proof attests that: inputs exist in tree, nullifiers are valid, balance is conserved.
    fn transfer(
        ref self: TContractState,
        proof: Span<felt252>,
        merkle_root: felt252,
        nullifiers: (felt252, felt252),
        output_commitments: (felt252, felt252),
    );

    /// Withdraw funds from the pool. Proves ownership of notes and releases tokens publicly.
    fn withdraw(
        ref self: TContractState,
        proof: Span<felt252>,
        merkle_root: felt252,
        nullifiers: (felt252, felt252),
        output_commitment: felt252,
        recipient: ContractAddress,
        amount: u256,
        asset_id: felt252,
    );

    // -- View functions --

    /// Get the current Merkle root.
    fn get_root(self: @TContractState) -> felt252;

    /// Get the total number of leaves (deposits + transfers) in the tree.
    fn get_leaf_count(self: @TContractState) -> u64;

    /// Check if a nullifier has been spent.
    fn is_nullifier_spent(self: @TContractState, nullifier: felt252) -> bool;

    /// Check if a root was ever a valid historical root.
    fn is_known_root(self: @TContractState, root: felt252) -> bool;

    /// Get the pool's total balance for a given asset.
    fn get_pool_balance(self: @TContractState, asset_id: felt252) -> u256;

    /// Check if the pool is paused.
    fn is_paused(self: @TContractState) -> bool;

    /// Get the configured fee recipient address.
    fn get_fee_recipient(self: @TContractState) -> ContractAddress;

    /// Get remaining rate-limit operations for the caller.
    fn get_remaining_rate_limit(self: @TContractState, caller: ContractAddress) -> u64;

    // -- Admin functions --

    /// Pause the pool (owner only). Blocks deposits, transfers, and withdrawals.
    fn pause(ref self: TContractState);

    /// Unpause the pool (owner only).
    fn unpause(ref self: TContractState);

    /// Update the fee recipient address (owner only).
    fn set_fee_recipient(ref self: TContractState, recipient: ContractAddress);

    /// Update the proof verifier contract (owner only).
    fn set_proof_verifier(ref self: TContractState, verifier: ContractAddress);

    /// Update the compliance oracle address (owner only).
    fn set_compliance_oracle(ref self: TContractState, oracle: ContractAddress);

    /// Get the current operator address.
    fn get_operator(self: @TContractState) -> ContractAddress;

    /// Set the operator address (owner only). The operator can pause/unpause
    /// and update the fee recipient without full owner privileges.
    fn set_operator(ref self: TContractState, operator: ContractAddress);
}

#[starknet::contract]
pub mod PrivacyPool {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starkprivacy_primitives::hash::poseidon_hash_2;
    use starkprivacy_primitives::types::MAX_DEPOSIT_AMOUNT;
    use starkprivacy_tree::merkle::{
        MerkleTree, MerkleTreeTrait, TREE_DEPTH, compute_zero_hashes,
    };
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starkprivacy_compliance::oracle::{IComplianceOracleDispatcher, IComplianceOracleDispatcherTrait};
    use starkprivacy_security::reentrancy_guard::ReentrancyGuard;
    use starkprivacy_security::rate_limiter::RateLimiter;
    use starkprivacy_circuits::metadata::ENVELOPE_SIZE;
    use super::{IProofVerifierDispatcher, IProofVerifierDispatcherTrait};

    /// Maximum number of historical roots to keep for validation.
    const ROOT_HISTORY_SIZE: u32 = 100;
    /// Default rate limit: 10 operations per window.
    const DEFAULT_MAX_OPS: u64 = 10;
    /// Default rate limit window: 60 seconds.
    const DEFAULT_WINDOW: u64 = 60;

    // ── Embedded security components ──────────────────────────
    component!(path: ReentrancyGuard, storage: reentrancy_guard, event: ReentrancyGuardEvent);
    component!(path: RateLimiter, storage: rate_limiter, event: RateLimiterEvent);

    impl ReentrancyGuardInternalImpl = ReentrancyGuard::ReentrancyGuardImpl<ContractState>;
    impl RateLimiterInternalImpl = RateLimiter::RateLimiterImpl<ContractState>;

    #[storage]
    struct Storage {
        // -- Merkle tree state --
        tree_root: felt252,
        tree_next_index: u64,
        tree_frontier: Map<u32, felt252>,

        // -- Nullifier state --
        nullifier_spent: Map<felt252, bool>,
        nullifier_count: u64,

        // -- Root history (ring buffer) --
        root_history: Map<u32, felt252>,
        root_history_index: u32,

        // -- Pool balances --
        pool_balance: Map<felt252, u256>,

        // -- Configuration --
        native_token: ContractAddress,
        compliance_oracle: ContractAddress,
        chain_id: felt252,
        app_id: felt252,
        owner: ContractAddress,
        operator: ContractAddress,
        proof_verifier: ContractAddress,
        fee_recipient: ContractAddress,
        paused: bool,

        // -- Embedded components --
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuard::Storage,
        #[substorage(v0)]
        rate_limiter: RateLimiter::Storage,
    }

    // -- Events --
    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Deposit: Deposit,
        Transfer: Transfer,
        Withdrawal: Withdrawal,
        NewRoot: NewRoot,
        Paused: Paused,
        Unpaused: Unpaused,
        FeeRecipientUpdated: FeeRecipientUpdated,
        ProofVerifierUpdated: ProofVerifierUpdated,
        ComplianceOracleUpdated: ComplianceOracleUpdated,
        OperatorUpdated: OperatorUpdated,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuard::Event,
        #[flat]
        RateLimiterEvent: RateLimiter::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Deposit {
        #[key]
        pub commitment: felt252,
        pub leaf_index: u64,
        pub amount: u256,
        pub asset_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Transfer {
        #[key]
        pub nullifier_1: felt252,
        #[key]
        pub nullifier_2: felt252,
        pub output_commitment_1: felt252,
        pub output_commitment_2: felt252,
        pub new_root: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Withdrawal {
        #[key]
        pub nullifier_1: felt252,
        #[key]
        pub nullifier_2: felt252,
        pub recipient: ContractAddress,
        pub amount: u256,
        pub asset_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NewRoot {
        pub root: felt252,
        pub leaf_index: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Paused {
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Unpaused {
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeeRecipientUpdated {
        pub old_recipient: ContractAddress,
        pub new_recipient: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProofVerifierUpdated {
        pub old_verifier: ContractAddress,
        pub new_verifier: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ComplianceOracleUpdated {
        pub old_oracle: ContractAddress,
        pub new_oracle: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OperatorUpdated {
        pub old_operator: ContractAddress,
        pub new_operator: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        native_token: ContractAddress,
        compliance_oracle: ContractAddress,
        chain_id: felt252,
        app_id: felt252,
        owner: ContractAddress,
    ) {
        // Initialize the Merkle tree
        let zeros = compute_zero_hashes();
        let empty_root = *zeros.at(TREE_DEPTH);

        self.tree_root.write(empty_root);
        self.tree_next_index.write(0);

        // Initialize frontier with zero hashes
        let mut level: u32 = 0;
        while level < TREE_DEPTH {
            self.tree_frontier.write(level, *zeros.at(level));
            level += 1;
        };

        // Store initial root in history
        self.root_history.write(0, empty_root);
        self.root_history_index.write(0);

        // Configuration
        self.native_token.write(native_token);
        self.compliance_oracle.write(compliance_oracle);
        self.chain_id.write(chain_id);
        self.app_id.write(app_id);
        self.owner.write(owner);
        self.paused.write(false);

        // Initialize rate limiter
        self.rate_limiter.initialize(DEFAULT_MAX_OPS, DEFAULT_WINDOW);
    }

    #[abi(embed_v0)]
    impl PrivacyPoolImpl of super::IPrivacyPool<ContractState> {
        fn deposit(
            ref self: ContractState, commitment: felt252, amount: u256, asset_id: felt252,
        ) {
            self._assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            self.rate_limiter.check_rate_limit(caller);

            // Validate inputs
            assert!(commitment != 0, "commitment cannot be zero");
            assert!(amount > 0, "amount must be positive");
            assert!(amount <= MAX_DEPOSIT_AMOUNT, "amount exceeds maximum");

            // Compliance check (if oracle configured)
            self._check_deposit_compliance(caller, amount, asset_id);

            // Transfer ERC-20 tokens from caller to pool (if token is configured)
            let token_addr = self.native_token.read();
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            if token_addr != zero_addr {
                let pool = get_contract_address();
                let token = IERC20Dispatcher { contract_address: token_addr };
                let success = token.transfer_from(caller, pool, amount);
                assert!(success, "ERC-20 transfer_from failed");
            }

            // Insert commitment into the Merkle tree
            let leaf_index = self.tree_next_index.read();
            let new_root = self._insert_leaf(commitment);

            // Update pool balance
            let current_balance = self.pool_balance.read(asset_id);
            self.pool_balance.write(asset_id, current_balance + amount);

            // Emit events
            self.emit(Deposit { commitment, leaf_index, amount, asset_id });
            self.emit(NewRoot { root: new_root, leaf_index: leaf_index + 1 });

            self.reentrancy_guard.end();
        }

        fn transfer(
            ref self: ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nullifiers: (felt252, felt252),
            output_commitments: (felt252, felt252),
        ) {
            self._assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            self.rate_limiter.check_rate_limit(caller);

            let (nf1, nf2) = nullifiers;
            let (oc1, oc2) = output_commitments;

            // Enforce fixed envelope size for metadata resistance
            self._assert_envelope_size(proof);

            // Validate the Merkle root is known
            assert!(self._is_known_root(merkle_root), "unknown merkle root");

            // Validate nullifiers are fresh
            assert!(!self.nullifier_spent.read(nf1), "nullifier 1 already spent");
            assert!(!self.nullifier_spent.read(nf2), "nullifier 2 already spent");
            assert!(nf1 != nf2, "duplicate nullifiers");

            // Validate output commitments
            assert!(oc1 != 0, "output commitment 1 cannot be zero");
            assert!(oc2 != 0, "output commitment 2 cannot be zero");

            // Compliance check for transfers
            self._check_transfer_compliance(nf1, nf2, oc1, oc2);

            // Verify proof via verifier contract (or fallback to basic check)
            self._verify_transfer_proof(proof, merkle_root, nf1, nf2, oc1, oc2);

            // Mark nullifiers as spent
            self.nullifier_spent.write(nf1, true);
            self.nullifier_spent.write(nf2, true);
            let count = self.nullifier_count.read();
            self.nullifier_count.write(count + 2);

            // Insert new commitments into the tree
            self._insert_leaf(oc1);
            let new_root = self._insert_leaf(oc2);

            let new_index = self.tree_next_index.read();

            self
                .emit(
                    Transfer {
                        nullifier_1: nf1,
                        nullifier_2: nf2,
                        output_commitment_1: oc1,
                        output_commitment_2: oc2,
                        new_root,
                    },
                );
            self.emit(NewRoot { root: new_root, leaf_index: new_index });

            self.reentrancy_guard.end();
        }

        fn withdraw(
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
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            self.rate_limiter.check_rate_limit(caller);

            let (nf1, nf2) = nullifiers;

            // Enforce fixed envelope size for metadata resistance
            self._assert_envelope_size(proof);

            // Validate the Merkle root
            assert!(self._is_known_root(merkle_root), "unknown merkle root");

            // Validate nullifiers
            assert!(!self.nullifier_spent.read(nf1), "nullifier 1 already spent");
            assert!(!self.nullifier_spent.read(nf2), "nullifier 2 already spent");
            assert!(nf1 != nf2, "duplicate nullifiers");

            // Validate withdrawal params
            assert!(amount > 0, "amount must be positive");
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            assert!(recipient != zero_addr, "invalid recipient");

            // Compliance check for withdrawals
            self._check_withdrawal_compliance(recipient, amount, asset_id);

            // Check pool has sufficient balance
            let current_balance = self.pool_balance.read(asset_id);
            assert!(current_balance >= amount, "insufficient pool balance");

            // Verify proof
            self._verify_withdraw_proof(proof, merkle_root, nf1, nf2, output_commitment, amount, asset_id);

            // Mark nullifiers as spent
            self.nullifier_spent.write(nf1, true);
            self.nullifier_spent.write(nf2, true);
            let count = self.nullifier_count.read();
            self.nullifier_count.write(count + 2);

            // Insert change commitment (if any)
            if output_commitment != 0 {
                self._insert_leaf(output_commitment);
            }

            // Deduct fee and update pool balance
            let fee_amount = self._compute_and_route_fee(amount, asset_id);
            self.pool_balance.write(asset_id, current_balance - amount);

            // Transfer tokens to recipient (if token is configured)
            let token_addr = self.native_token.read();
            if token_addr != zero_addr {
                let token = IERC20Dispatcher { contract_address: token_addr };
                let net_amount = amount - fee_amount;
                let success = token.transfer(recipient, net_amount);
                assert!(success, "ERC-20 transfer failed");

                // Route fee to fee_recipient (if configured and fee > 0)
                if fee_amount > 0 {
                    let fee_addr = self.fee_recipient.read();
                    if fee_addr != zero_addr {
                        let fee_ok = token.transfer(fee_addr, fee_amount);
                        assert!(fee_ok, "ERC-20 fee transfer failed");
                    }
                }
            }

            let new_index = self.tree_next_index.read();
            self
                .emit(
                    Withdrawal {
                        nullifier_1: nf1, nullifier_2: nf2, recipient, amount, asset_id,
                    },
                );
            self.emit(NewRoot { root: self.tree_root.read(), leaf_index: new_index });

            self.reentrancy_guard.end();
        }

        fn get_root(self: @ContractState) -> felt252 {
            self.tree_root.read()
        }

        fn get_leaf_count(self: @ContractState) -> u64 {
            self.tree_next_index.read()
        }

        fn is_nullifier_spent(self: @ContractState, nullifier: felt252) -> bool {
            self.nullifier_spent.read(nullifier)
        }

        fn is_known_root(self: @ContractState, root: felt252) -> bool {
            self._is_known_root(root)
        }

        fn get_pool_balance(self: @ContractState, asset_id: felt252) -> u256 {
            self.pool_balance.read(asset_id)
        }

        fn is_paused(self: @ContractState) -> bool {
            self.paused.read()
        }

        fn get_fee_recipient(self: @ContractState) -> ContractAddress {
            self.fee_recipient.read()
        }

        fn get_remaining_rate_limit(self: @ContractState, caller: ContractAddress) -> u64 {
            self.rate_limiter.get_remaining_ops(caller)
        }

        fn pause(ref self: ContractState) {
            self._assert_operator_or_owner();
            assert!(!self.paused.read(), "already paused");
            self.paused.write(true);
            self.emit(Paused { by: get_caller_address() });
        }

        fn unpause(ref self: ContractState) {
            self._assert_operator_or_owner();
            assert!(self.paused.read(), "not paused");
            self.paused.write(false);
            self.emit(Unpaused { by: get_caller_address() });
        }

        fn set_fee_recipient(ref self: ContractState, recipient: ContractAddress) {
            self._assert_operator_or_owner();
            let old = self.fee_recipient.read();
            self.fee_recipient.write(recipient);
            self.emit(FeeRecipientUpdated { old_recipient: old, new_recipient: recipient });
        }

        fn set_proof_verifier(ref self: ContractState, verifier: ContractAddress) {
            self._assert_owner();
            let old = self.proof_verifier.read();
            self.proof_verifier.write(verifier);
            self.emit(ProofVerifierUpdated { old_verifier: old, new_verifier: verifier });
        }

        fn set_compliance_oracle(ref self: ContractState, oracle: ContractAddress) {
            self._assert_owner();
            let old = self.compliance_oracle.read();
            self.compliance_oracle.write(oracle);
            self.emit(ComplianceOracleUpdated { old_oracle: old, new_oracle: oracle });
        }

        fn get_operator(self: @ContractState) -> ContractAddress {
            self.operator.read()
        }

        fn set_operator(ref self: ContractState, operator: ContractAddress) {
            self._assert_owner();
            let old = self.operator.read();
            self.operator.write(operator);
            self.emit(OperatorUpdated { old_operator: old, new_operator: operator });
        }
    }

    // -- Internal functions --
    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Assert the caller is the owner.
        fn _assert_owner(self: @ContractState) {
            let caller = get_caller_address();
            assert!(caller == self.owner.read(), "caller is not owner");
        }

        /// Assert the caller is the owner or the operator.
        fn _assert_operator_or_owner(self: @ContractState) {
            let caller = get_caller_address();
            let is_owner = caller == self.owner.read();
            let operator_addr = self.operator.read();
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            let is_operator = operator_addr != zero_addr && caller == operator_addr;
            assert!(is_owner || is_operator, "caller is not owner or operator");
        }

        /// Assert the pool is not paused.
        fn _assert_not_paused(self: @ContractState) {
            assert!(!self.paused.read(), "pool is paused");
        }

        /// Assert proof envelope has the correct fixed size for metadata resistance.
        /// When a verifier is configured, proofs must be exactly ENVELOPE_SIZE elements.
        /// Legacy mode (no verifier) allows any non-empty proof.
        fn _assert_envelope_size(self: @ContractState, proof: Span<felt252>) {
            let verifier_addr = self.proof_verifier.read();
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            if verifier_addr != zero_addr {
                assert!(proof.len() == ENVELOPE_SIZE, "proof must be exactly ENVELOPE_SIZE elements");
            }
        }

        /// Check deposit compliance via the configured oracle.
        fn _check_deposit_compliance(
            self: @ContractState,
            depositor: ContractAddress,
            amount: u256,
            asset_id: felt252,
        ) {
            let oracle_addr = self.compliance_oracle.read();
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            if oracle_addr != zero_addr {
                let oracle = IComplianceOracleDispatcher { contract_address: oracle_addr };
                let allowed = oracle.check_deposit(depositor, amount, asset_id);
                assert!(allowed, "deposit blocked by compliance oracle");
            }
        }

        /// Check withdrawal compliance via the configured oracle.
        fn _check_withdrawal_compliance(
            self: @ContractState,
            recipient: ContractAddress,
            amount: u256,
            asset_id: felt252,
        ) {
            let oracle_addr = self.compliance_oracle.read();
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            if oracle_addr != zero_addr {
                let oracle = IComplianceOracleDispatcher { contract_address: oracle_addr };
                let allowed = oracle.check_withdrawal(recipient, amount, asset_id);
                assert!(allowed, "withdrawal blocked by compliance oracle");
            }
        }

        /// Check transfer compliance via the configured oracle.
        fn _check_transfer_compliance(
            self: @ContractState,
            nf1: felt252,
            nf2: felt252,
            oc1: felt252,
            oc2: felt252,
        ) {
            let oracle_addr = self.compliance_oracle.read();
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            if oracle_addr != zero_addr {
                let oracle = IComplianceOracleDispatcher { contract_address: oracle_addr };
                let nullifiers: Array<felt252> = array![nf1, nf2];
                let commitments: Array<felt252> = array![oc1, oc2];
                let allowed = oracle.check_transfer(nullifiers.span(), commitments.span());
                assert!(allowed, "transfer blocked by compliance oracle");
            }
        }

        /// Compute withdrawal fee (0.1% = 1/1000) and return the fee amount.
        /// Fee is kept in pool balance for the fee recipient to claim.
        fn _compute_and_route_fee(self: @ContractState, amount: u256, _asset_id: felt252) -> u256 {
            let fee_addr = self.fee_recipient.read();
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            if fee_addr == zero_addr {
                return 0;
            }
            // 0.1% fee (amount / 1000)
            amount / 1000
        }

        /// Verify a transfer proof via the verifier contract or fallback.
        fn _verify_transfer_proof(
            self: @ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nf0: felt252,
            nf1: felt252,
            oc0: felt252,
            oc1: felt252,
        ) {
            let verifier_addr = self.proof_verifier.read();
            let zero_addr: ContractAddress = 0.try_into().unwrap();

            if verifier_addr != zero_addr {
                let verifier = IProofVerifierDispatcher { contract_address: verifier_addr };
                let valid = verifier.verify_transfer_proof(
                    proof, merkle_root, nf0, nf1, oc0, oc1,
                );
                assert!(valid, "transfer proof verification failed");
            } else {
                assert!(proof.len() > 0, "proof cannot be empty");
            }
        }

        /// Verify a withdraw proof via the verifier contract or fallback.
        fn _verify_withdraw_proof(
            self: @ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nf0: felt252,
            nf1: felt252,
            change_commitment: felt252,
            amount: u256,
            asset_id: felt252,
        ) {
            let verifier_addr = self.proof_verifier.read();
            let zero_addr: ContractAddress = 0.try_into().unwrap();

            if verifier_addr != zero_addr {
                let verifier = IProofVerifierDispatcher { contract_address: verifier_addr };
                let valid = verifier.verify_withdraw_proof(
                    proof, merkle_root, nf0, nf1, change_commitment, amount, asset_id,
                );
                assert!(valid, "withdraw proof verification failed");
            } else {
                assert!(proof.len() > 0, "proof cannot be empty");
            }
        }

        /// Insert a leaf into the Merkle tree and return the new root.
        fn _insert_leaf(ref self: ContractState, leaf: felt252) -> felt252 {
            let idx = self.tree_next_index.read();
            let zeros = compute_zero_hashes();

            let mut current = leaf;
            let mut current_idx = idx;
            let mut level: u32 = 0;

            while level < TREE_DEPTH {
                let is_right = current_idx % 2;

                if is_right == 1 {
                    let left = self.tree_frontier.read(level);
                    current = poseidon_hash_2(left, current);
                } else {
                    self.tree_frontier.write(level, current);
                    let zero_sibling = *zeros.at(level);
                    current = poseidon_hash_2(current, zero_sibling);
                }

                current_idx = current_idx / 2;
                level += 1;
            };

            self.tree_root.write(current);
            self.tree_next_index.write(idx + 1);

            // Store in root history (ring buffer)
            let hist_idx = self.root_history_index.read();
            let next_hist = (hist_idx + 1) % ROOT_HISTORY_SIZE;
            self.root_history.write(next_hist, current);
            self.root_history_index.write(next_hist);

            current
        }

        /// Check if a root exists in the history ring buffer.
        fn _is_known_root(self: @ContractState, root: felt252) -> bool {
            // Current root is always valid
            if root == self.tree_root.read() {
                return true;
            }

            let mut i: u32 = 0;
            let mut found = false;
            while i < ROOT_HISTORY_SIZE {
                if self.root_history.read(i) == root {
                    found = true;
                    break;
                }
                i += 1;
            };
            found
        }
    }
}
