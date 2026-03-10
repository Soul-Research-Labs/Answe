/// Core type aliases and constants for StarkPrivacy.
///
/// All types are felt252-based to leverage Starknet's native field arithmetic.

/// Private spending key — used to authorize note spending and derive nullifiers.
pub type SpendingKey = felt252;

/// Viewing key — derived from spending key, enables decryption of incoming notes.
pub type ViewingKey = felt252;

/// A nullifier is the proof that a note has been spent.
pub type NullifierValue = felt252;

/// Merkle root of the note commitment tree.
pub type MerkleRoot = felt252;

/// Asset identifier (0 = native ETH, others = ERC-20 token class hashes).
pub type AssetId = felt252;

/// Zero felt constant.
pub const ZERO_FELT: felt252 = 0;

/// Maximum deposit amount (2^64 - 1) to ensure range-check compatibility.
pub const MAX_DEPOSIT_AMOUNT: u256 = 0xFFFFFFFFFFFFFFFF;

/// Fixed-size proof envelope in bytes for metadata resistance.
pub const PROOF_ENVELOPE_SIZE: u32 = 2048;

/// Merkle tree depth — 2^32 leaves support billions of notes.
pub const TREE_DEPTH: u32 = 32;

/// Domain separator tags for Poseidon hashing.
pub mod domains {
    pub const NOTE_COMMITMENT: felt252 = 'SP_NOTE_COMMIT_V1';
    pub const NULLIFIER_V2: felt252 = 'SP_NULLIFIER_V2';
    pub const NULLIFIER_DOMAIN: felt252 = 'SP_NULL_DOMAIN';
    pub const STEALTH_DERIVE: felt252 = 'SP_STEALTH_V1';
    pub const EPOCH_ROOT: felt252 = 'SP_EPOCH_ROOT';
    pub const BRIDGE_LOCK: felt252 = 'SP_BRIDGE_LOCK';
}
