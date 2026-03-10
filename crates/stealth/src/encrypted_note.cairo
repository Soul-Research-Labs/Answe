/// EncryptedNote — on-chain encrypted note storage with fixed-size padding.
///
/// Notes are encrypted off-chain using ECDH + symmetric encryption,
/// then stored on-chain for the recipient to scan and trial-decrypt.
///
/// Fixed-size padding prevents metadata leakage about note contents.
/// Each encrypted note is exactly NOTE_PADDED_SIZE felt252 elements.

/// Fixed size for encrypted notes (metadata resistance).
/// 8 felts = 256 bytes of encrypted data + padding.
pub const NOTE_PADDED_SIZE: u32 = 8;

/// An encrypted note stored on-chain.
/// Contains the ciphertext, the ephemeral public key for ECDH,
/// and the commitment to link to the Merkle tree.
#[derive(Drop, Copy, Serde)]
pub struct EncryptedNote {
    /// Ephemeral public key for ECDH (x-coordinate).
    pub ephemeral_pub_x: felt252,
    /// The note commitment (links to Merkle tree leaf).
    pub commitment: felt252,
    /// Tag for fast scan filtering: Poseidon(viewing_key, ephemeral_pub) truncated.
    pub scan_tag: felt252,
}

use starkprivacy_primitives::hash::poseidon_hash_2;

/// Compute a scan tag = Poseidon(shared_secret_component, epoch_counter).
/// Recipients can quickly filter notes by checking the scan tag before
/// doing full trial decryption.
pub fn compute_scan_tag(
    viewing_pub_x: felt252, ephemeral_pub_x: felt252, epoch: u64,
) -> felt252 {
    let base = poseidon_hash_2(viewing_pub_x, ephemeral_pub_x);
    let epoch_felt: felt252 = epoch.into();
    poseidon_hash_2(base, epoch_felt)
}

/// Pad an encrypted note payload to exactly NOTE_PADDED_SIZE felts.
/// If the input is shorter, pad with zeros. If longer, truncate.
pub fn pad_note_payload(payload: Span<felt252>) -> Array<felt252> {
    let mut result: Array<felt252> = array![];
    let mut i: u32 = 0;

    while i < NOTE_PADDED_SIZE {
        if i < payload.len() {
            result.append(*payload.at(i));
        } else {
            result.append(0);
        }
        i += 1;
    };

    result
}

#[cfg(test)]
mod tests {
    use super::{pad_note_payload, NOTE_PADDED_SIZE, compute_scan_tag};

    #[test]
    fn test_pad_note_payload_short() {
        let payload: Array<felt252> = array![1, 2, 3];
        let padded = pad_note_payload(payload.span());
        assert!(padded.len() == NOTE_PADDED_SIZE, "wrong length");
        assert!(*padded.at(0) == 1, "wrong val 0");
        assert!(*padded.at(1) == 2, "wrong val 1");
        assert!(*padded.at(2) == 3, "wrong val 2");
        assert!(*padded.at(3) == 0, "should be padded");
        assert!(*padded.at(7) == 0, "should be padded");
    }

    #[test]
    fn test_pad_note_payload_exact() {
        let payload: Array<felt252> = array![1, 2, 3, 4, 5, 6, 7, 8];
        let padded = pad_note_payload(payload.span());
        assert!(padded.len() == NOTE_PADDED_SIZE, "wrong length");
        assert!(*padded.at(7) == 8, "wrong last val");
    }

    #[test]
    fn test_scan_tag_deterministic() {
        let tag1 = compute_scan_tag(100, 200, 1);
        let tag2 = compute_scan_tag(100, 200, 1);
        assert!(tag1 == tag2, "should be deterministic");
    }

    #[test]
    fn test_scan_tag_differs_by_epoch() {
        let tag1 = compute_scan_tag(100, 200, 1);
        let tag2 = compute_scan_tag(100, 200, 2);
        assert!(tag1 != tag2, "different epochs should differ");
    }
}
