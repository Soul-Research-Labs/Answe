/// Verifier — proof envelope encoding/decoding and verification dispatch.
///
/// This module handles the serialization format for proof data that flows
/// between off-chain provers and on-chain contracts.
///
/// Proof Envelope Format (felt252 array):
/// [0]     = proof_type (1 = transfer, 2 = withdraw)
/// [1]     = merkle_root
/// [2]     = nullifier_0
/// [3]     = nullifier_1
/// [4..N]  = type-specific public inputs
/// [N+1..] = STARK proof data (opaque bytes from prover)

/// Proof types
pub const PROOF_TYPE_TRANSFER: felt252 = 1;
pub const PROOF_TYPE_WITHDRAW: felt252 = 2;

/// Decode the proof type from a proof envelope.
pub fn decode_proof_type(envelope: Span<felt252>) -> felt252 {
    assert!(envelope.len() >= 5, "envelope too short");
    *envelope.at(0)
}

/// Encode a transfer proof envelope from public inputs + raw proof.
pub fn encode_transfer_envelope(
    merkle_root: felt252,
    nullifier_0: felt252,
    nullifier_1: felt252,
    output_commitment_0: felt252,
    output_commitment_1: felt252,
    fee: felt252,
    proof_data: Span<felt252>,
) -> Array<felt252> {
    let mut envelope: Array<felt252> = array![
        PROOF_TYPE_TRANSFER,
        merkle_root,
        nullifier_0,
        nullifier_1,
        output_commitment_0,
        output_commitment_1,
        fee,
    ];
    let mut i: u32 = 0;
    while i < proof_data.len() {
        envelope.append(*proof_data.at(i));
        i += 1;
    };
    envelope
}

/// Encode a withdraw proof envelope.
pub fn encode_withdraw_envelope(
    merkle_root: felt252,
    nullifier_0: felt252,
    nullifier_1: felt252,
    change_commitment: felt252,
    exit_value: felt252,
    fee: felt252,
    asset_id: felt252,
    proof_data: Span<felt252>,
) -> Array<felt252> {
    let mut envelope: Array<felt252> = array![
        PROOF_TYPE_WITHDRAW,
        merkle_root,
        nullifier_0,
        nullifier_1,
        change_commitment,
        exit_value,
        fee,
        asset_id,
    ];
    let mut i: u32 = 0;
    while i < proof_data.len() {
        envelope.append(*proof_data.at(i));
        i += 1;
    };
    envelope
}

/// Decoded transfer public inputs from an envelope.
#[derive(Drop, Copy)]
pub struct DecodedTransfer {
    pub merkle_root: felt252,
    pub nullifier_0: felt252,
    pub nullifier_1: felt252,
    pub output_commitment_0: felt252,
    pub output_commitment_1: felt252,
    pub fee: felt252,
}

/// Decode transfer public inputs from an envelope.
pub fn decode_transfer_envelope(envelope: Span<felt252>) -> DecodedTransfer {
    assert!(envelope.len() >= 7, "transfer envelope too short");
    assert!(*envelope.at(0) == PROOF_TYPE_TRANSFER, "not a transfer proof");
    DecodedTransfer {
        merkle_root: *envelope.at(1),
        nullifier_0: *envelope.at(2),
        nullifier_1: *envelope.at(3),
        output_commitment_0: *envelope.at(4),
        output_commitment_1: *envelope.at(5),
        fee: *envelope.at(6),
    }
}

/// Decoded withdraw public inputs from an envelope.
#[derive(Drop, Copy)]
pub struct DecodedWithdraw {
    pub merkle_root: felt252,
    pub nullifier_0: felt252,
    pub nullifier_1: felt252,
    pub change_commitment: felt252,
    pub exit_value: felt252,
    pub fee: felt252,
    pub asset_id: felt252,
}

/// Decode withdraw public inputs from an envelope.
pub fn decode_withdraw_envelope(envelope: Span<felt252>) -> DecodedWithdraw {
    assert!(envelope.len() >= 8, "withdraw envelope too short");
    assert!(*envelope.at(0) == PROOF_TYPE_WITHDRAW, "not a withdraw proof");
    DecodedWithdraw {
        merkle_root: *envelope.at(1),
        nullifier_0: *envelope.at(2),
        nullifier_1: *envelope.at(3),
        change_commitment: *envelope.at(4),
        exit_value: *envelope.at(5),
        fee: *envelope.at(6),
        asset_id: *envelope.at(7),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        encode_transfer_envelope, decode_transfer_envelope,
        encode_withdraw_envelope, decode_withdraw_envelope,
        decode_proof_type, PROOF_TYPE_TRANSFER, PROOF_TYPE_WITHDRAW,
    };

    #[test]
    fn test_transfer_envelope_roundtrip() {
        let proof_data: Array<felt252> = array![0xAA, 0xBB, 0xCC];
        let envelope = encode_transfer_envelope(
            0x1111, 0x2222, 0x3333, 0x4444, 0x5555, 10, proof_data.span(),
        );

        assert!(decode_proof_type(envelope.span()) == PROOF_TYPE_TRANSFER, "wrong type");

        let decoded = decode_transfer_envelope(envelope.span());
        assert!(decoded.merkle_root == 0x1111, "root mismatch");
        assert!(decoded.nullifier_0 == 0x2222, "nf0 mismatch");
        assert!(decoded.nullifier_1 == 0x3333, "nf1 mismatch");
        assert!(decoded.output_commitment_0 == 0x4444, "oc0 mismatch");
        assert!(decoded.output_commitment_1 == 0x5555, "oc1 mismatch");
        assert!(decoded.fee == 10, "fee mismatch");

        // Total length: 7 header + 3 proof = 10
        assert!(envelope.len() == 10, "envelope length mismatch");
    }

    #[test]
    fn test_withdraw_envelope_roundtrip() {
        let proof_data: Array<felt252> = array![0xDD, 0xEE];
        let envelope = encode_withdraw_envelope(
            0x1111, 0x2222, 0x3333, 0x4444, 150, 10, 0, proof_data.span(),
        );

        assert!(decode_proof_type(envelope.span()) == PROOF_TYPE_WITHDRAW, "wrong type");

        let decoded = decode_withdraw_envelope(envelope.span());
        assert!(decoded.merkle_root == 0x1111, "root mismatch");
        assert!(decoded.nullifier_0 == 0x2222, "nf0 mismatch");
        assert!(decoded.nullifier_1 == 0x3333, "nf1 mismatch");
        assert!(decoded.change_commitment == 0x4444, "change mismatch");
        assert!(decoded.exit_value == 150, "exit mismatch");
        assert!(decoded.fee == 10, "fee mismatch");
        assert!(decoded.asset_id == 0, "asset mismatch");

        // Total length: 8 header + 2 proof = 10
        assert!(envelope.len() == 10, "envelope length mismatch");
    }

    #[test]
    #[should_panic(expected: "not a transfer proof")]
    fn test_decode_wrong_type_rejected() {
        let envelope: Array<felt252> = array![
            PROOF_TYPE_WITHDRAW, 0, 0, 0, 0, 0, 0,
        ];
        decode_transfer_envelope(envelope.span());
    }
}
