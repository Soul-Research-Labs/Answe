/// MetadataResistance — fixed-size proof envelopes and dummy padding.
///
/// All proof submissions use exactly ENVELOPE_SIZE felt252 elements,
/// preventing observers from distinguishing between transfers, withdrawals,
/// and dummy operations based on payload size.

/// Fixed envelope size in felt252 elements.
/// Chosen to accommodate the largest proof type with room for expansion.
pub const ENVELOPE_SIZE: u32 = 64;

/// Proof envelope types.
pub const PROOF_TYPE_TRANSFER: felt252 = 1;
pub const PROOF_TYPE_WITHDRAW: felt252 = 2;
pub const PROOF_TYPE_DUMMY: felt252 = 3;

/// A fixed-size proof envelope for metadata resistance.
/// Every transaction submitted to the pool uses one of these,
/// regardless of the actual operation type.
#[derive(Drop, Copy, Serde)]
pub struct ProofEnvelope {
    /// Type of proof (transfer, withdraw, or dummy).
    pub proof_type: felt252,
    /// Padded payload (always ENVELOPE_SIZE elements).
    pub payload_hash: felt252,
    /// Envelope sequence number (for ordering in batch).
    pub sequence: u64,
}

/// Pad a proof payload to exactly ENVELOPE_SIZE elements.
pub fn pad_envelope(payload: Span<felt252>) -> Array<felt252> {
    let mut result: Array<felt252> = array![];
    let mut i: u32 = 0;

    while i < ENVELOPE_SIZE {
        if i < payload.len() {
            result.append(*payload.at(i));
        } else {
            result.append(0);
        }
        i += 1;
    };

    result
}

/// Create a dummy envelope (no-op, for batch padding).
pub fn create_dummy_envelope(sequence: u64) -> (ProofEnvelope, Array<felt252>) {
    let envelope = ProofEnvelope {
        proof_type: PROOF_TYPE_DUMMY,
        payload_hash: 0,
        sequence,
    };
    let payload = pad_envelope(array![].span());
    (envelope, payload)
}

use starkprivacy_primitives::hash::poseidon_hash_2;

/// Hash an envelope for compact representation.
pub fn hash_envelope(envelope: @ProofEnvelope) -> felt252 {
    let seq_felt: felt252 = (*envelope.sequence).into();
    let type_seq = poseidon_hash_2(*envelope.proof_type, seq_felt);
    poseidon_hash_2(type_seq, *envelope.payload_hash)
}

#[cfg(test)]
mod tests {
    use super::{
        pad_envelope, create_dummy_envelope, hash_envelope, ENVELOPE_SIZE, PROOF_TYPE_DUMMY,
        PROOF_TYPE_TRANSFER, ProofEnvelope,
    };

    #[test]
    fn test_pad_envelope_exact_size() {
        let payload: Array<felt252> = array![1, 2, 3];
        let padded = pad_envelope(payload.span());
        assert!(padded.len() == ENVELOPE_SIZE, "wrong size");
    }

    #[test]
    fn test_pad_envelope_preserves_data() {
        let payload: Array<felt252> = array![42, 99];
        let padded = pad_envelope(payload.span());
        assert!(*padded.at(0) == 42, "wrong 0");
        assert!(*padded.at(1) == 99, "wrong 1");
        assert!(*padded.at(2) == 0, "should be padded");
    }

    #[test]
    fn test_dummy_envelope() {
        let (env, payload) = create_dummy_envelope(1);
        assert!(env.proof_type == PROOF_TYPE_DUMMY, "wrong type");
        assert!(env.sequence == 1, "wrong seq");
        assert!(payload.len() == ENVELOPE_SIZE, "wrong size");
    }

    #[test]
    fn test_hash_envelope_deterministic() {
        let env = ProofEnvelope {
            proof_type: PROOF_TYPE_TRANSFER, payload_hash: 100, sequence: 5,
        };
        let h1 = hash_envelope(@env);
        let h2 = hash_envelope(@env);
        assert!(h1 == h2, "should be deterministic");
    }

    #[test]
    fn test_hash_envelope_differs_by_type() {
        let e1 = ProofEnvelope {
            proof_type: PROOF_TYPE_TRANSFER, payload_hash: 100, sequence: 1,
        };
        let e2 = ProofEnvelope {
            proof_type: PROOF_TYPE_DUMMY, payload_hash: 100, sequence: 1,
        };
        assert!(hash_envelope(@e1) != hash_envelope(@e2), "different types should differ");
    }
}
