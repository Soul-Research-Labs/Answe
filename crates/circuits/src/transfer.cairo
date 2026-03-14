/// TransferCircuit — STARK-provable 2-in-2-out private transfer.
///
/// This module defines the constraint logic (not an on-chain contract) that would
/// be executed in a STARK prover context. It validates:
///
/// 1. Each input note commitment matches Poseidon(owner, value, asset_id, blinding)
/// 2. Each nullifier is correctly derived: Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))
/// 3. Each input note exists in the Merkle tree (proof of membership)
/// 4. Each output commitment is well-formed
/// 5. Value is conserved: sum(input_values) == sum(output_values) + fee
/// 6. Range: all values are within valid bounds (0..2^64)
///
/// In Starknet's execution model, this runs as a Cairo program whose execution
/// trace is verified by the STARK prover (stone-prover / s-two).

use starkprivacy_primitives::hash::poseidon_hash_2;
use starkprivacy_primitives::note::{Note, compute_note_commitment, compute_nullifier_v2};
use starkprivacy_tree::merkle::verify_merkle_proof;

/// Maximum allowed value per note (2^64 - 1).
const MAX_NOTE_VALUE: u128 = 18446744073709551615; // 2^64 - 1

/// Public inputs to the transfer circuit (revealed on-chain).
#[derive(Drop, Copy, Serde)]
pub struct TransferPublicInputs {
    /// The Merkle root at which the input notes exist.
    pub merkle_root: felt252,
    /// Nullifier for input note 0.
    pub nullifier_0: felt252,
    /// Nullifier for input note 1.
    pub nullifier_1: felt252,
    /// Commitment for output note 0.
    pub output_commitment_0: felt252,
    /// Commitment for output note 1.
    pub output_commitment_1: felt252,
    /// Fee (public, goes to relayer or is burned).
    pub fee: u128,
    /// Chain ID for domain separation.
    pub chain_id: felt252,
    /// App ID for domain separation.
    pub app_id: felt252,
}

/// Private witness for the transfer circuit (never revealed on-chain).
#[derive(Drop, Copy)]
pub struct TransferWitness {
    /// Spending key of the note owner.
    pub spending_key: felt252,
    /// Input note 0.
    pub input_note_0: Note,
    /// Input note 1.
    pub input_note_1: Note,
    /// Merkle proof for input note 0 (array of TREE_DEPTH siblings).
    pub merkle_path_0: Span<felt252>,
    /// Leaf index of input note 0 in the tree.
    pub leaf_index_0: u64,
    /// Merkle proof for input note 1.
    pub merkle_path_1: Span<felt252>,
    /// Leaf index of input note 1 in the tree.
    pub leaf_index_1: u64,
    /// Output note 0.
    pub output_note_0: Note,
    /// Output note 1.
    pub output_note_1: Note,
}

/// Verify all constraints of a 2-in-2-out private transfer.
///
/// Returns `true` if all constraints are satisfied, panics otherwise.
/// In a STARK-proving context, this function is executed and its trace is proved.
pub fn verify_transfer(
    public: @TransferPublicInputs, witness: @TransferWitness,
) -> bool {
    // ── 1. Verify input commitments ──────────────────────────────
    let cm0 = compute_note_commitment(witness.input_note_0);
    let cm1 = compute_note_commitment(witness.input_note_1);

    // ── 2. Verify nullifiers match the derived values ────────────
    let expected_nf0 = compute_nullifier_v2(
        *witness.spending_key, cm0, *public.chain_id, *public.app_id,
    );
    let expected_nf1 = compute_nullifier_v2(
        *witness.spending_key, cm1, *public.chain_id, *public.app_id,
    );
    assert!(expected_nf0 == *public.nullifier_0, "nullifier 0 mismatch");
    assert!(expected_nf1 == *public.nullifier_1, "nullifier 1 mismatch");

    // Nullifiers must be distinct
    assert!(*public.nullifier_0 != *public.nullifier_1, "duplicate nullifiers");

    // ── 3. Verify Merkle membership ──────────────────────────────
    assert!(
        verify_merkle_proof(*public.merkle_root, cm0, *witness.leaf_index_0, *witness.merkle_path_0),
        "input 0 not in tree",
    );
    assert!(
        verify_merkle_proof(*public.merkle_root, cm1, *witness.leaf_index_1, *witness.merkle_path_1),
        "input 1 not in tree",
    );

    // ── 4. Verify output commitments ─────────────────────────────
    let expected_oc0 = compute_note_commitment(witness.output_note_0);
    let expected_oc1 = compute_note_commitment(witness.output_note_1);
    assert!(expected_oc0 == *public.output_commitment_0, "output commitment 0 mismatch");
    assert!(expected_oc1 == *public.output_commitment_1, "output commitment 1 mismatch");

    // ── 5. Range checks ─────────────────────────────────────────
    // Note values are felt252; we interpret them as u128 for range checks.
    let iv0: u128 = (*witness.input_note_0).value.try_into().expect('input value 0 overflow');
    let iv1: u128 = (*witness.input_note_1).value.try_into().expect('input value 1 overflow');
    let ov0: u128 = (*witness.output_note_0).value.try_into().expect('output value 0 overflow');
    let ov1: u128 = (*witness.output_note_1).value.try_into().expect('output value 1 overflow');

    assert!(iv0 <= MAX_NOTE_VALUE, "input note 0 value exceeds 2^64");
    assert!(iv1 <= MAX_NOTE_VALUE, "input note 1 value exceeds 2^64");
    assert!(ov0 <= MAX_NOTE_VALUE, "output note 0 value exceeds 2^64");
    assert!(ov1 <= MAX_NOTE_VALUE, "output note 1 value exceeds 2^64");

    // ── 6. Balance conservation ──────────────────────────────────
    // sum(inputs) == sum(outputs) + fee
    let total_in: u128 = iv0 + iv1;
    let total_out: u128 = ov0 + ov1 + *public.fee;
    assert!(total_in == total_out, "balance not conserved");

    // ── 7. Asset consistency ─────────────────────────────────────
    // All input and output notes must reference the same asset_id.
    // Without this, a malicious prover could mix value across asset types.
    let asset = (*witness.input_note_0).asset_id;
    assert!((*witness.input_note_1).asset_id == asset, "input asset mismatch");
    assert!((*witness.output_note_0).asset_id == asset, "output 0 asset mismatch");
    assert!((*witness.output_note_1).asset_id == asset, "output 1 asset mismatch");

    // ── 8. Owner verification ────────────────────────────────────
    // Both input notes must be owned by the spending key
    let owner_hash = poseidon_hash_2(*witness.spending_key, 0);
    assert!((*witness.input_note_0).owner == owner_hash, "input 0 not owned by spender");
    assert!((*witness.input_note_1).owner == owner_hash, "input 1 not owned by spender");

    true
}

#[cfg(test)]
mod tests {
    use super::{TransferPublicInputs, TransferWitness, verify_transfer};
    use starkprivacy_primitives::hash::poseidon_hash_2;
    use starkprivacy_primitives::note::{Note, compute_note_commitment, compute_nullifier_v2};
    use starkprivacy_tree::merkle::{MerkleTreeTrait, TREE_DEPTH, compute_zero_hashes};

    fn make_owner(sk: felt252) -> felt252 {
        poseidon_hash_2(sk, 0)
    }

    /// Helper: build a 2-leaf Merkle tree and return (root, path0, path1).
    fn build_two_leaf_tree(
        cm0: felt252, cm1: felt252,
    ) -> (felt252, Array<felt252>, Array<felt252>) {
        let (mut tree, mut frontier) = MerkleTreeTrait::new();
        MerkleTreeTrait::insert(ref tree, ref frontier, cm0);
        let root = MerkleTreeTrait::insert(ref tree, ref frontier, cm1);

        let zeros = compute_zero_hashes();
        let mut path0: Array<felt252> = array![];
        path0.append(cm1);
        let mut lvl: u32 = 1;
        while lvl < TREE_DEPTH {
            path0.append(*zeros.at(lvl));
            lvl += 1;
        };
        let mut path1: Array<felt252> = array![];
        path1.append(cm0);
        let mut lvl: u32 = 1;
        while lvl < TREE_DEPTH {
            path1.append(*zeros.at(lvl));
            lvl += 1;
        };

        (root, path0, path1)
    }

    #[test]
    fn test_transfer_circuit_valid() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);
        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        // Output notes (conserve value: 100 + 200 = 150 + 150 + 0 fee)
        let out0 = Note { owner: 0xBEEF, value: 150, asset_id: 0, blinding: 0x3333 };
        let out1 = Note { owner: 0xCAFE, value: 150, asset_id: 0, blinding: 0x4444 };
        let oc0 = compute_note_commitment(@out0);
        let oc1 = compute_note_commitment(@out1);

        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = TransferPublicInputs {
            merkle_root: root, nullifier_0: nf0, nullifier_1: nf1,
            output_commitment_0: oc0, output_commitment_1: oc1,
            fee: 0, chain_id, app_id,
        };
        let witness = TransferWitness {
            spending_key: sk,
            input_note_0: note0, input_note_1: note1,
            merkle_path_0: path0.span(), leaf_index_0: 0,
            merkle_path_1: path1.span(), leaf_index_1: 1,
            output_note_0: out0, output_note_1: out1,
        };

        assert!(verify_transfer(@public, @witness), "valid transfer should pass");
    }

    #[test]
    fn test_transfer_with_fee() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);
        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        // 100 + 200 = 290 + 0 + 10 fee
        let out0 = Note { owner: 0xBEEF, value: 290, asset_id: 0, blinding: 0x3333 };
        let out1 = Note { owner: 0xCAFE, value: 0, asset_id: 0, blinding: 0x4444 };
        let oc0 = compute_note_commitment(@out0);
        let oc1 = compute_note_commitment(@out1);
        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = TransferPublicInputs {
            merkle_root: root, nullifier_0: nf0, nullifier_1: nf1,
            output_commitment_0: oc0, output_commitment_1: oc1,
            fee: 10, chain_id, app_id,
        };
        let witness = TransferWitness {
            spending_key: sk,
            input_note_0: note0, input_note_1: note1,
            merkle_path_0: path0.span(), leaf_index_0: 0,
            merkle_path_1: path1.span(), leaf_index_1: 1,
            output_note_0: out0, output_note_1: out1,
        };

        assert!(verify_transfer(@public, @witness), "transfer with fee should pass");
    }

    #[test]
    #[should_panic(expected: "balance not conserved")]
    fn test_transfer_balance_mismatch_rejected() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);
        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        // Inflated output: 100 + 200 != 400 + 100
        let out0 = Note { owner: 0xBEEF, value: 400, asset_id: 0, blinding: 0x3333 };
        let out1 = Note { owner: 0xCAFE, value: 100, asset_id: 0, blinding: 0x4444 };
        let oc0 = compute_note_commitment(@out0);
        let oc1 = compute_note_commitment(@out1);
        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = TransferPublicInputs {
            merkle_root: root, nullifier_0: nf0, nullifier_1: nf1,
            output_commitment_0: oc0, output_commitment_1: oc1,
            fee: 0, chain_id, app_id,
        };
        let witness = TransferWitness {
            spending_key: sk,
            input_note_0: note0, input_note_1: note1,
            merkle_path_0: path0.span(), leaf_index_0: 0,
            merkle_path_1: path1.span(), leaf_index_1: 1,
            output_note_0: out0, output_note_1: out1,
        };
        verify_transfer(@public, @witness);
    }

    #[test]
    #[should_panic(expected: "nullifier 0 mismatch")]
    fn test_transfer_wrong_nullifier_rejected() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);
        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        let out0 = Note { owner: 0xBEEF, value: 150, asset_id: 0, blinding: 0x3333 };
        let out1 = Note { owner: 0xCAFE, value: 150, asset_id: 0, blinding: 0x4444 };
        let oc0 = compute_note_commitment(@out0);
        let oc1 = compute_note_commitment(@out1);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = TransferPublicInputs {
            merkle_root: root,
            nullifier_0: 0xBAD, // wrong nullifier
            nullifier_1: nf1,
            output_commitment_0: oc0, output_commitment_1: oc1,
            fee: 0, chain_id, app_id,
        };
        let witness = TransferWitness {
            spending_key: sk,
            input_note_0: note0, input_note_1: note1,
            merkle_path_0: path0.span(), leaf_index_0: 0,
            merkle_path_1: path1.span(), leaf_index_1: 1,
            output_note_0: out0, output_note_1: out1,
        };
        verify_transfer(@public, @witness);
    }

    #[test]
    #[should_panic(expected: "input 0 not in tree")]
    fn test_transfer_wrong_merkle_proof_rejected() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);
        let (root, _path0, path1) = build_two_leaf_tree(cm0, cm1);

        // Wrong proof — bad siblings
        let mut bad_path: Array<felt252> = array![];
        let mut lvl: u32 = 0;
        while lvl < TREE_DEPTH {
            bad_path.append(0xDEAD);
            lvl += 1;
        };

        let out0 = Note { owner: 0xBEEF, value: 150, asset_id: 0, blinding: 0x3333 };
        let out1 = Note { owner: 0xCAFE, value: 150, asset_id: 0, blinding: 0x4444 };
        let oc0 = compute_note_commitment(@out0);
        let oc1 = compute_note_commitment(@out1);
        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = TransferPublicInputs {
            merkle_root: root, nullifier_0: nf0, nullifier_1: nf1,
            output_commitment_0: oc0, output_commitment_1: oc1,
            fee: 0, chain_id, app_id,
        };
        let witness = TransferWitness {
            spending_key: sk,
            input_note_0: note0, input_note_1: note1,
            merkle_path_0: bad_path.span(), leaf_index_0: 0,
            merkle_path_1: path1.span(), leaf_index_1: 1,
            output_note_0: out0, output_note_1: out1,
        };
        verify_transfer(@public, @witness);
    }

    #[test]
    #[should_panic(expected: "input asset mismatch")]
    fn test_transfer_mixed_assets_rejected() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        // Input notes with different asset_ids
        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 1, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);
        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        let out0 = Note { owner: 0xBEEF, value: 150, asset_id: 0, blinding: 0x3333 };
        let out1 = Note { owner: 0xCAFE, value: 150, asset_id: 0, blinding: 0x4444 };
        let oc0 = compute_note_commitment(@out0);
        let oc1 = compute_note_commitment(@out1);
        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = TransferPublicInputs {
            merkle_root: root, nullifier_0: nf0, nullifier_1: nf1,
            output_commitment_0: oc0, output_commitment_1: oc1,
            fee: 0, chain_id, app_id,
        };
        let witness = TransferWitness {
            spending_key: sk,
            input_note_0: note0, input_note_1: note1,
            merkle_path_0: path0.span(), leaf_index_0: 0,
            merkle_path_1: path1.span(), leaf_index_1: 1,
            output_note_0: out0, output_note_1: out1,
        };
        verify_transfer(@public, @witness);
    }

    #[test]
    #[should_panic(expected: "output 0 asset mismatch")]
    fn test_transfer_output_asset_mismatch_rejected() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);
        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        // Output note 0 has a different asset_id than inputs
        let out0 = Note { owner: 0xBEEF, value: 150, asset_id: 1, blinding: 0x3333 };
        let out1 = Note { owner: 0xCAFE, value: 150, asset_id: 0, blinding: 0x4444 };
        let oc0 = compute_note_commitment(@out0);
        let oc1 = compute_note_commitment(@out1);
        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = TransferPublicInputs {
            merkle_root: root, nullifier_0: nf0, nullifier_1: nf1,
            output_commitment_0: oc0, output_commitment_1: oc1,
            fee: 0, chain_id, app_id,
        };
        let witness = TransferWitness {
            spending_key: sk,
            input_note_0: note0, input_note_1: note1,
            merkle_path_0: path0.span(), leaf_index_0: 0,
            merkle_path_1: path1.span(), leaf_index_1: 1,
            output_note_0: out0, output_note_1: out1,
        };
        verify_transfer(@public, @witness);
    }
}
