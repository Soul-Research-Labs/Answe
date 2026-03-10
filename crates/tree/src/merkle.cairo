/// Incremental Poseidon Merkle tree (depth 32, append-only).
///
/// This is the core data structure backing the privacy pool. Each leaf is a
/// NoteCommitment. The root is published on-chain and used in zero-knowledge
/// proofs to validate Merkle membership without revealing which leaf was spent.
///
/// Algorithm: standard incremental Merkle tree using a "frontier" array.
/// The frontier stores one node per level — the latest node at that level
/// that hasn't yet been paired. On insert, we walk up from the leaf,
/// pairing with the frontier node if the current index has a 1-bit at that level.
use starkprivacy_primitives::hash::poseidon_hash_2;

/// Tree depth — supports 2^32 (~4 billion) leaves.
pub const TREE_DEPTH: u32 = 32;

/// Precomputed zero hashes for each level of an empty tree.
/// zero_hashes[0] = 0 (empty leaf)
/// zero_hashes[i] = Poseidon(zero_hashes[i-1], zero_hashes[i-1])
pub fn compute_zero_hashes() -> Array<felt252> {
    let mut zeros: Array<felt252> = array![];
    zeros.append(0); // level 0: empty leaf = 0
    let mut i: u32 = 1;
    while i <= TREE_DEPTH {
        let prev = *zeros.at(i - 1);
        zeros.append(poseidon_hash_2(prev, prev));
        i += 1;
    };
    zeros
}

/// Append-only incremental Merkle tree stored in a component-friendly struct.
#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct MerkleTree {
    /// Current Merkle root.
    pub root: felt252,
    /// Number of leaves inserted so far.
    pub next_index: u64,
}

#[generate_trait]
pub impl MerkleTreeTrait of MerkleTreeTraitDef {
    /// Create a new empty Merkle tree. Returns tree + initial frontier.
    fn new() -> (MerkleTree, Array<felt252>) {
        let zeros = compute_zero_hashes();
        let root = *zeros.at(TREE_DEPTH);

        // Frontier: one slot per level, initialized to zero hashes
        let mut frontier: Array<felt252> = array![];
        let mut i: u32 = 0;
        while i < TREE_DEPTH {
            frontier.append(*zeros.at(i));
            i += 1;
        };

        (MerkleTree { root, next_index: 0 }, frontier)
    }

    /// Insert a leaf and return the new root.
    /// `frontier` is mutated in place (caller must persist it).
    fn insert(ref self: MerkleTree, ref frontier: Array<felt252>, leaf: felt252) -> felt252 {
        let idx: u64 = self.next_index;
        let zeros = compute_zero_hashes();

        let mut current = leaf;
        let mut current_idx = idx;
        let mut level: u32 = 0;

        let mut new_frontier: Array<felt252> = array![];

        while level < TREE_DEPTH {
            let is_right = current_idx % 2;

            if is_right == 1 {
                // Current node goes right; left sibling is in frontier
                let left = *frontier.at(level);
                current = poseidon_hash_2(left, current);
                // Frontier at this level stays the same
                new_frontier.append(*frontier.at(level));
            } else {
                // Current node goes left; right sibling is zero hash
                new_frontier.append(current);
                let zero_sibling = *zeros.at(level);
                current = poseidon_hash_2(current, zero_sibling);
            }

            current_idx = current_idx / 2;
            level += 1;
        };

        self.root = current;
        self.next_index = idx + 1;
        frontier = new_frontier;
        current
    }
}

/// Compute a Merkle root from a leaf, its index, and a proof path.
/// Used by the verifier to check membership.
pub fn compute_root_from_path(leaf: felt252, index: u64, path: Span<felt252>) -> felt252 {
    assert!(path.len() == TREE_DEPTH, "path length must equal tree depth");

    let mut current = leaf;
    let mut current_idx = index;
    let mut i: u32 = 0;

    while i < TREE_DEPTH {
        let sibling = *path.at(i);
        if current_idx % 2 == 0 {
            current = poseidon_hash_2(current, sibling);
        } else {
            current = poseidon_hash_2(sibling, current);
        }
        current_idx = current_idx / 2;
        i += 1;
    };

    current
}

/// Verify that a leaf exists at the given index in the tree with the provided root.
pub fn verify_merkle_proof(
    root: felt252, leaf: felt252, index: u64, path: Span<felt252>,
) -> bool {
    let computed_root = compute_root_from_path(leaf, index, path);
    computed_root == root
}


#[cfg(test)]
mod tests {
    use super::{
        MerkleTree, MerkleTreeTrait, TREE_DEPTH, compute_zero_hashes, compute_root_from_path,
        verify_merkle_proof,
    };

    #[test]
    fn test_zero_hashes_length() {
        let zeros = compute_zero_hashes();
        assert!(zeros.len() == TREE_DEPTH + 1, "should have depth+1 zero hashes");
    }

    #[test]
    fn test_zero_hashes_first_is_zero() {
        let zeros = compute_zero_hashes();
        assert!(*zeros.at(0) == 0, "first zero hash should be 0");
    }

    #[test]
    fn test_zero_hashes_deterministic() {
        let z1 = compute_zero_hashes();
        let z2 = compute_zero_hashes();
        let mut i: u32 = 0;
        while i <= TREE_DEPTH {
            assert!(*z1.at(i) == *z2.at(i), "zero hashes must be deterministic");
            i += 1;
        };
    }

    #[test]
    fn test_empty_tree_root() {
        let (tree, _frontier) = MerkleTreeTrait::new();
        let zeros = compute_zero_hashes();
        assert!(tree.root == *zeros.at(TREE_DEPTH), "empty tree root == top zero hash");
        assert!(tree.next_index == 0, "empty tree next_index should be 0");
    }

    #[test]
    fn test_insert_single_leaf() {
        let (mut tree, mut frontier) = MerkleTreeTrait::new();
        let leaf: felt252 = 0x1234;
        let new_root = tree.insert(ref frontier, leaf);
        assert!(new_root != 0, "root should be nonzero after insert");
        assert!(tree.next_index == 1, "next_index should be 1 after one insert");
    }

    #[test]
    fn test_insert_changes_root() {
        let (mut tree, mut frontier) = MerkleTreeTrait::new();
        let old_root = tree.root;
        tree.insert(ref frontier, 0xAAAA);
        assert!(tree.root != old_root, "root must change after insert");
    }

    #[test]
    fn test_insert_two_leaves_different_roots() {
        let (mut tree, mut frontier) = MerkleTreeTrait::new();
        tree.insert(ref frontier, 0xAAAA);
        let root_after_first = tree.root;
        tree.insert(ref frontier, 0xBBBB);
        assert!(tree.root != root_after_first, "root must change after second insert");
        assert!(tree.next_index == 2, "next_index should be 2");
    }

    #[test]
    fn test_compute_root_from_path_with_zero_proof() {
        // For leaf at index 0 in an otherwise-empty tree,
        // the proof path is all zero hashes at each level.
        let zeros = compute_zero_hashes();
        let leaf: felt252 = 0x1234;

        let mut path: Array<felt252> = array![];
        let mut i: u32 = 0;
        while i < TREE_DEPTH {
            path.append(*zeros.at(i));
            i += 1;
        };

        let computed_root = compute_root_from_path(leaf, 0, path.span());

        // Now insert the same leaf into a fresh tree and compare
        let (mut tree, mut frontier) = MerkleTreeTrait::new();
        tree.insert(ref frontier, leaf);

        assert!(computed_root == tree.root, "computed root should match tree root");
    }

    #[test]
    fn test_verify_merkle_proof_valid() {
        let zeros = compute_zero_hashes();
        let leaf: felt252 = 0x5678;

        let (mut tree, mut frontier) = MerkleTreeTrait::new();
        tree.insert(ref frontier, leaf);

        let mut path: Array<felt252> = array![];
        let mut i: u32 = 0;
        while i < TREE_DEPTH {
            path.append(*zeros.at(i));
            i += 1;
        };

        assert!(
            verify_merkle_proof(tree.root, leaf, 0, path.span()),
            "proof should be valid for inserted leaf",
        );
    }

    #[test]
    fn test_verify_merkle_proof_invalid_leaf() {
        let zeros = compute_zero_hashes();
        let leaf: felt252 = 0x5678;

        let (mut tree, mut frontier) = MerkleTreeTrait::new();
        tree.insert(ref frontier, leaf);

        let mut path: Array<felt252> = array![];
        let mut i: u32 = 0;
        while i < TREE_DEPTH {
            path.append(*zeros.at(i));
            i += 1;
        };

        let wrong_leaf: felt252 = 0x9999;
        assert!(
            !verify_merkle_proof(tree.root, wrong_leaf, 0, path.span()),
            "proof should be invalid for wrong leaf",
        );
    }
}
