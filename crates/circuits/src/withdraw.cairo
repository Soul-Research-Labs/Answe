/// WithdrawCircuit — STARK-provable withdrawal proof.
///
/// Extends the TransferCircuit with a public exit value. The prover demonstrates:
///
/// 1. Ownership of input notes via spending key
/// 2. Notes exist in the Merkle tree
/// 3. Nullifiers are correctly derived (domain-separated)
/// 4. Balance: sum(inputs) == change_output + exit_value + fee
/// 5. Range checks on all values
///
/// exit_value and recipient are public — they're revealed on-chain for the
/// actual token transfer. The change output stays private in the pool.

use starkprivacy_primitives::hash::poseidon_hash_2;
use starkprivacy_primitives::note::{Note, compute_note_commitment, compute_nullifier_v2};
use starkprivacy_tree::merkle::{verify_merkle_proof, TREE_DEPTH};

const MAX_NOTE_VALUE: u128 = 18446744073709551615; // 2^64 - 1

/// Public inputs for withdraw circuit.
#[derive(Drop, Copy, Serde)]
pub struct WithdrawPublicInputs {
    pub merkle_root: felt252,
    pub nullifier_0: felt252,
    pub nullifier_1: felt252,
    /// The change commitment (stays in the pool).
    pub change_commitment: felt252,
    /// The amount being withdrawn publicly.
    pub exit_value: u128,
    /// Fee for the relayer.
    pub fee: u128,
    /// Asset ID being withdrawn.
    pub asset_id: felt252,
    pub chain_id: felt252,
    pub app_id: felt252,
}

/// Private witness for the withdraw circuit.
#[derive(Drop, Copy)]
pub struct WithdrawWitness {
    pub spending_key: felt252,
    pub input_note_0: Note,
    pub input_note_1: Note,
    pub merkle_path_0: Span<felt252>,
    pub leaf_index_0: u64,
    pub merkle_path_1: Span<felt252>,
    pub leaf_index_1: u64,
    /// The change note (private output that stays in the pool).
    pub change_note: Note,
}

/// Verify all constraints of a withdrawal proof.
pub fn verify_withdraw(
    public: @WithdrawPublicInputs, witness: @WithdrawWitness,
) -> bool {
    // ── 1. Verify input commitments ──────────────────────────────
    let cm0 = compute_note_commitment(witness.input_note_0);
    let cm1 = compute_note_commitment(witness.input_note_1);

    // ── 2. Verify nullifiers ─────────────────────────────────────
    let expected_nf0 = compute_nullifier_v2(
        *witness.spending_key, cm0, *public.chain_id, *public.app_id,
    );
    let expected_nf1 = compute_nullifier_v2(
        *witness.spending_key, cm1, *public.chain_id, *public.app_id,
    );
    assert!(expected_nf0 == *public.nullifier_0, "nullifier 0 mismatch");
    assert!(expected_nf1 == *public.nullifier_1, "nullifier 1 mismatch");
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

    // ── 4. Verify change commitment ──────────────────────────────
    let expected_change = compute_note_commitment(witness.change_note);
    assert!(expected_change == *public.change_commitment, "change commitment mismatch");

    // ── 5. Range checks ─────────────────────────────────────────
    let iv0: u128 = (*witness.input_note_0).value.try_into().expect('input value 0 overflow');
    let iv1: u128 = (*witness.input_note_1).value.try_into().expect('input value 1 overflow');
    let cv: u128 = (*witness.change_note).value.try_into().expect('change value overflow');

    assert!(iv0 <= MAX_NOTE_VALUE, "input 0 value exceeds 2^64");
    assert!(iv1 <= MAX_NOTE_VALUE, "input 1 value exceeds 2^64");
    assert!(cv <= MAX_NOTE_VALUE, "change value exceeds 2^64");
    assert!(*public.exit_value <= MAX_NOTE_VALUE, "exit value exceeds 2^64");

    // ── 6. Balance conservation ──────────────────────────────────
    // sum(inputs) == change + exit_value + fee
    let total_in: u128 = iv0 + iv1;
    let total_out: u128 = cv + *public.exit_value + *public.fee;
    assert!(total_in == total_out, "balance not conserved");

    // ── 7. Asset consistency ─────────────────────────────────────
    assert!((*witness.input_note_0).asset_id == *public.asset_id, "input 0 asset mismatch");
    assert!((*witness.input_note_1).asset_id == *public.asset_id, "input 1 asset mismatch");
    assert!((*witness.change_note).asset_id == *public.asset_id, "change asset mismatch");

    // ── 8. Owner verification ────────────────────────────────────
    let owner_hash = poseidon_hash_2(*witness.spending_key, 0);
    assert!((*witness.input_note_0).owner == owner_hash, "input 0 not owned by spender");
    assert!((*witness.input_note_1).owner == owner_hash, "input 1 not owned by spender");

    true
}

#[cfg(test)]
mod tests {
    use super::{WithdrawPublicInputs, WithdrawWitness, verify_withdraw};
    use starkprivacy_primitives::hash::poseidon_hash_2;
    use starkprivacy_primitives::note::{Note, compute_note_commitment, compute_nullifier_v2};
    use starkprivacy_tree::merkle::{MerkleTreeTrait, TREE_DEPTH, compute_zero_hashes};

    fn make_owner(sk: felt252) -> felt252 {
        poseidon_hash_2(sk, 0)
    }

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
    fn test_withdraw_valid() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);

        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        // Withdraw 150, keep 150 as change, 0 fee
        let change = Note { owner, value: 150, asset_id: 0, blinding: 0x5555 };
        let change_cm = compute_note_commitment(@change);

        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = WithdrawPublicInputs {
            merkle_root: root,
            nullifier_0: nf0,
            nullifier_1: nf1,
            change_commitment: change_cm,
            exit_value: 150,
            fee: 0,
            asset_id: 0,
            chain_id,
            app_id,
        };
        let witness = WithdrawWitness {
            spending_key: sk,
            input_note_0: note0,
            input_note_1: note1,
            merkle_path_0: path0.span(),
            leaf_index_0: 0,
            merkle_path_1: path1.span(),
            leaf_index_1: 1,
            change_note: change,
        };

        assert!(verify_withdraw(@public, @witness), "valid withdraw should pass");
    }

    #[test]
    fn test_withdraw_with_fee() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);

        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        // 300 total = 140 change + 150 exit + 10 fee
        let change = Note { owner, value: 140, asset_id: 0, blinding: 0x5555 };
        let change_cm = compute_note_commitment(@change);
        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = WithdrawPublicInputs {
            merkle_root: root,
            nullifier_0: nf0,
            nullifier_1: nf1,
            change_commitment: change_cm,
            exit_value: 150,
            fee: 10,
            asset_id: 0,
            chain_id,
            app_id,
        };
        let witness = WithdrawWitness {
            spending_key: sk,
            input_note_0: note0,
            input_note_1: note1,
            merkle_path_0: path0.span(),
            leaf_index_0: 0,
            merkle_path_1: path1.span(),
            leaf_index_1: 1,
            change_note: change,
        };

        assert!(verify_withdraw(@public, @witness), "withdraw with fee should pass");
    }

    #[test]
    fn test_withdraw_full_amount() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);

        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        // Full withdrawal: 300 exit, 0 change, 0 fee
        let change = Note { owner, value: 0, asset_id: 0, blinding: 0x5555 };
        let change_cm = compute_note_commitment(@change);
        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = WithdrawPublicInputs {
            merkle_root: root,
            nullifier_0: nf0,
            nullifier_1: nf1,
            change_commitment: change_cm,
            exit_value: 300,
            fee: 0,
            asset_id: 0,
            chain_id,
            app_id,
        };
        let witness = WithdrawWitness {
            spending_key: sk,
            input_note_0: note0,
            input_note_1: note1,
            merkle_path_0: path0.span(),
            leaf_index_0: 0,
            merkle_path_1: path1.span(),
            leaf_index_1: 1,
            change_note: change,
        };

        assert!(verify_withdraw(@public, @witness), "full withdrawal should pass");
    }

    #[test]
    #[should_panic(expected: "balance not conserved")]
    fn test_withdraw_inflated_exit_rejected() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        let note0 = Note { owner, value: 100, asset_id: 0, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);

        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        // Trying to withdraw more than input total
        let change = Note { owner, value: 100, asset_id: 0, blinding: 0x5555 };
        let change_cm = compute_note_commitment(@change);
        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = WithdrawPublicInputs {
            merkle_root: root,
            nullifier_0: nf0,
            nullifier_1: nf1,
            change_commitment: change_cm,
            exit_value: 500, // 100 + 500 != 300
            fee: 0,
            asset_id: 0,
            chain_id,
            app_id,
        };
        let witness = WithdrawWitness {
            spending_key: sk,
            input_note_0: note0,
            input_note_1: note1,
            merkle_path_0: path0.span(),
            leaf_index_0: 0,
            merkle_path_1: path1.span(),
            leaf_index_1: 1,
            change_note: change,
        };
        verify_withdraw(@public, @witness);
    }

    #[test]
    #[should_panic(expected: "input 0 asset mismatch")]
    fn test_withdraw_asset_mismatch_rejected() {
        let sk: felt252 = 0xABCD;
        let owner = make_owner(sk);
        let chain_id: felt252 = 'SN_SEPOLIA';
        let app_id: felt252 = 'STARKPRIVACY';

        // Note has asset_id=1, but withdrawal claims asset_id=0
        let note0 = Note { owner, value: 100, asset_id: 1, blinding: 0x1111 };
        let note1 = Note { owner, value: 200, asset_id: 0, blinding: 0x2222 };
        let cm0 = compute_note_commitment(@note0);
        let cm1 = compute_note_commitment(@note1);

        let (root, path0, path1) = build_two_leaf_tree(cm0, cm1);

        let change = Note { owner, value: 150, asset_id: 0, blinding: 0x5555 };
        let change_cm = compute_note_commitment(@change);
        let nf0 = compute_nullifier_v2(sk, cm0, chain_id, app_id);
        let nf1 = compute_nullifier_v2(sk, cm1, chain_id, app_id);

        let public = WithdrawPublicInputs {
            merkle_root: root,
            nullifier_0: nf0,
            nullifier_1: nf1,
            change_commitment: change_cm,
            exit_value: 150,
            fee: 0,
            asset_id: 0, // claims asset 0, but note0 is asset 1
            chain_id,
            app_id,
        };
        let witness = WithdrawWitness {
            spending_key: sk,
            input_note_0: note0,
            input_note_1: note1,
            merkle_path_0: path0.span(),
            leaf_index_0: 0,
            merkle_path_1: path1.span(),
            leaf_index_1: 1,
            change_note: change,
        };
        verify_withdraw(@public, @witness);
    }
}
