/// StarkPrivacy Primitives — core cryptographic types and helpers.
///
/// All operations use Starknet's native felt252 field (p = 2^251 + 17*2^192 + 1)
/// and native Poseidon/Pedersen hash builtins for zero-cost in-circuit operations.

pub mod note;
pub mod hash;
pub mod types;

pub use note::{Note, NoteCommitment, compute_note_commitment};
pub use hash::{poseidon_hash_2, poseidon_hash_3, poseidon_hash_4, domain_hash};
pub use types::{
    SpendingKey, ViewingKey, NullifierValue, MerkleRoot, AssetId, ZERO_FELT, MAX_DEPOSIT_AMOUNT,
    PROOF_ENVELOPE_SIZE,
};
