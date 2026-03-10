/// StarkPrivacy Merkle Tree — Poseidon-based append-only incremental Merkle tree.
///
/// Ported from Lumora's `lumora-tree` crate. Uses depth-32 with Poseidon hash
/// built on Starknet's native builtins for zero-cost hashing.
///
/// Design:
/// - Append-only: leaves can only be added, never removed
/// - Incremental: maintains a "frontier" array for O(log n) root updates
/// - On-chain storage: root + frontier + next_index stored in contract state

pub mod merkle;

pub use merkle::{
    MerkleTree, MerkleTreeTrait, TREE_DEPTH, compute_root_from_path, verify_merkle_proof,
    compute_zero_hashes,
};
