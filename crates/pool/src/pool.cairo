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
use starknet::ContractAddress;

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

    /// Maximum number of historical roots to keep for validation.
    const ROOT_HISTORY_SIZE: u32 = 100;

    #[storage]
    struct Storage {
        // -- Merkle tree state --
        tree_root: felt252,
        tree_next_index: u64,
        /// Frontier array stored per-level: frontier[level] = felt252
        tree_frontier: Map<u32, felt252>,

        // -- Nullifier state --
        nullifier_spent: Map<felt252, bool>,
        nullifier_count: u64,

        // -- Root history (ring buffer) --
        root_history: Map<u32, felt252>,
        root_history_index: u32,

        // -- Pool balances --
        /// pool_balance[asset_id] = total shielded balance
        pool_balance: Map<felt252, u256>,

        // -- Configuration --
        /// ERC-20 token contract for native asset (0 = ETH via payable)
        native_token: ContractAddress,
        /// Optional compliance oracle (zero address = disabled)
        compliance_oracle: ContractAddress,
        /// Chain ID for domain-separated nullifiers
        chain_id: felt252,
        /// Application ID for domain-separated nullifiers
        app_id: felt252,
        /// Owner for admin functions
        owner: ContractAddress,
    }

    // -- Events --
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
        Transfer: Transfer,
        Withdrawal: Withdrawal,
        NewRoot: NewRoot,
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        commitment: felt252,
        leaf_index: u64,
        amount: u256,
        asset_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        #[key]
        nullifier_1: felt252,
        #[key]
        nullifier_2: felt252,
        output_commitment_1: felt252,
        output_commitment_2: felt252,
        new_root: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawal {
        #[key]
        nullifier_1: felt252,
        #[key]
        nullifier_2: felt252,
        recipient: ContractAddress,
        amount: u256,
        asset_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct NewRoot {
        root: felt252,
        leaf_index: u64,
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
    }

    #[abi(embed_v0)]
    impl PrivacyPoolImpl of super::IPrivacyPool<ContractState> {
        fn deposit(
            ref self: ContractState, commitment: felt252, amount: u256, asset_id: felt252,
        ) {
            // Validate inputs
            assert!(commitment != 0, "commitment cannot be zero");
            assert!(amount > 0, "amount must be positive");
            assert!(amount <= MAX_DEPOSIT_AMOUNT, "amount exceeds maximum");

            // TODO: Transfer tokens from caller to pool
            // For MVP, we track balances internally without actual ERC-20 transfers.
            // In production: IERC20Dispatcher { native_token }.transfer_from(caller, self,
            // amount)

            // Insert commitment into the Merkle tree
            let leaf_index = self.tree_next_index.read();
            let new_root = self._insert_leaf(commitment);

            // Update pool balance
            let current_balance = self.pool_balance.read(asset_id);
            self.pool_balance.write(asset_id, current_balance + amount);

            // Emit events
            self.emit(Deposit { commitment, leaf_index, amount, asset_id });
            self.emit(NewRoot { root: new_root, leaf_index: leaf_index + 1 });
        }

        fn transfer(
            ref self: ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nullifiers: (felt252, felt252),
            output_commitments: (felt252, felt252),
        ) {
            let (nf1, nf2) = nullifiers;
            let (oc1, oc2) = output_commitments;

            // Validate the Merkle root is known
            assert!(self._is_known_root(merkle_root), "unknown merkle root");

            // Validate nullifiers are fresh
            assert!(!self.nullifier_spent.read(nf1), "nullifier 1 already spent");
            assert!(!self.nullifier_spent.read(nf2), "nullifier 2 already spent");
            assert!(nf1 != nf2, "duplicate nullifiers");

            // Validate output commitments
            assert!(oc1 != 0, "output commitment 1 cannot be zero");
            assert!(oc2 != 0, "output commitment 2 cannot be zero");

            // TODO: Verify STARK proof
            // In production, this calls the Cairo proof verifier.
            // For MVP, we accept any non-empty proof.
            assert!(proof.len() > 0, "proof cannot be empty");

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
            let (nf1, nf2) = nullifiers;

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

            // Check pool has sufficient balance
            let current_balance = self.pool_balance.read(asset_id);
            assert!(current_balance >= amount, "insufficient pool balance");

            // TODO: Verify STARK proof
            assert!(proof.len() > 0, "proof cannot be empty");

            // Mark nullifiers as spent
            self.nullifier_spent.write(nf1, true);
            self.nullifier_spent.write(nf2, true);
            let count = self.nullifier_count.read();
            self.nullifier_count.write(count + 2);

            // Insert change commitment (if any)
            if output_commitment != 0 {
                self._insert_leaf(output_commitment);
            }

            // Update pool balance
            self.pool_balance.write(asset_id, current_balance - amount);

            // TODO: Transfer tokens to recipient
            // In production: IERC20Dispatcher { native_token }.transfer(recipient, amount)

            let new_index = self.tree_next_index.read();
            self
                .emit(
                    Withdrawal {
                        nullifier_1: nf1, nullifier_2: nf2, recipient, amount, asset_id,
                    },
                );
            self.emit(NewRoot { root: self.tree_root.read(), leaf_index: new_index });
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
    }

    // -- Internal functions --
    #[generate_trait]
    impl InternalImpl of InternalTrait {
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
