/// Note — the fundamental unit of value in StarkPrivacy.
///
/// A note represents a private balance entry in the Merkle tree. It contains:
/// - owner: the spending key hash that controls this note
/// - value: the amount (as felt252, must be < 2^64)
/// - asset_id: which token (0 = native ETH)
/// - blinding: random blinding factor for hiding the commitment
///
/// The commitment is: Poseidon(owner, value, asset_id, blinding)
/// This commitment is what gets stored in the Merkle tree.
use super::hash::poseidon_hash_4;
use super::types::{AssetId, SpendingKey};

/// A private note in the StarkPrivacy system.
#[derive(Drop, Copy, Serde)]
pub struct Note {
    pub owner: felt252,
    pub value: felt252,
    pub asset_id: AssetId,
    pub blinding: felt252,
}

/// The Poseidon commitment of a Note — stored as a Merkle leaf.
pub type NoteCommitment = felt252;

/// Compute the Poseidon commitment for a note.
/// commitment = Poseidon(owner, value, asset_id, blinding)
pub fn compute_note_commitment(note: @Note) -> NoteCommitment {
    poseidon_hash_4(*note.owner, *note.value, *note.asset_id, *note.blinding)
}

/// Compute a nullifier (V2, domain-separated) for a note.
///
/// nullifier = Poseidon(Poseidon(spending_key, commitment), Poseidon(chain_id, app_id))
///
/// This ensures the same note produces different nullifiers on different chains,
/// preventing cross-chain replay while enabling cross-chain privacy flows.
pub fn compute_nullifier_v2(
    spending_key: SpendingKey,
    commitment: NoteCommitment,
    chain_id: felt252,
    app_id: felt252,
) -> felt252 {
    let inner = super::hash::poseidon_hash_2(spending_key, commitment);
    let domain = super::hash::poseidon_hash_2(chain_id, app_id);
    super::hash::poseidon_hash_2(inner, domain)
}

#[cfg(test)]
mod tests {
    use super::{Note, compute_note_commitment, compute_nullifier_v2};

    fn sample_note() -> Note {
        Note { owner: 0xDEAD, value: 100, asset_id: 0, blinding: 0xBEEF }
    }

    #[test]
    fn test_commitment_deterministic() {
        let note = sample_note();
        let c1 = compute_note_commitment(@note);
        let c2 = compute_note_commitment(@note);
        assert!(c1 == c2, "commitment must be deterministic");
    }

    #[test]
    fn test_commitment_changes_with_value() {
        let n1 = Note { owner: 0xDEAD, value: 100, asset_id: 0, blinding: 0xBEEF };
        let n2 = Note { owner: 0xDEAD, value: 200, asset_id: 0, blinding: 0xBEEF };
        let c1 = compute_note_commitment(@n1);
        let c2 = compute_note_commitment(@n2);
        assert!(c1 != c2, "different values must produce different commitments");
    }

    #[test]
    fn test_commitment_changes_with_blinding() {
        let n1 = Note { owner: 0xDEAD, value: 100, asset_id: 0, blinding: 0xBEEF };
        let n2 = Note { owner: 0xDEAD, value: 100, asset_id: 0, blinding: 0xCAFE };
        let c1 = compute_note_commitment(@n1);
        let c2 = compute_note_commitment(@n2);
        assert!(c1 != c2, "different blindings must produce different commitments");
    }

    #[test]
    fn test_nullifier_v2_deterministic() {
        let note = sample_note();
        let cm = compute_note_commitment(@note);
        let n1 = compute_nullifier_v2(0xABCD, cm, 1, 42);
        let n2 = compute_nullifier_v2(0xABCD, cm, 1, 42);
        assert!(n1 == n2, "nullifier must be deterministic");
    }

    #[test]
    fn test_nullifier_v2_domain_separation() {
        let note = sample_note();
        let cm = compute_note_commitment(@note);
        // Same key + commitment, different chain_id
        let n1 = compute_nullifier_v2(0xABCD, cm, 1, 42);
        let n2 = compute_nullifier_v2(0xABCD, cm, 2, 42);
        assert!(n1 != n2, "different chains must produce different nullifiers");
    }

    #[test]
    fn test_nullifier_v2_app_separation() {
        let note = sample_note();
        let cm = compute_note_commitment(@note);
        // Same chain, different app_id
        let n1 = compute_nullifier_v2(0xABCD, cm, 1, 42);
        let n2 = compute_nullifier_v2(0xABCD, cm, 1, 99);
        assert!(n1 != n2, "different apps must produce different nullifiers");
    }

    #[test]
    fn test_nullifier_v2_key_binding() {
        let note = sample_note();
        let cm = compute_note_commitment(@note);
        let n1 = compute_nullifier_v2(0xABCD, cm, 1, 42);
        let n2 = compute_nullifier_v2(0x1234, cm, 1, 42);
        assert!(n1 != n2, "different keys must produce different nullifiers");
    }
}
