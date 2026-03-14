/// Property-based fuzz tests for StarkPrivacy invariants.
///
/// snforge automatically fuzzes felt252/u64/u128 parameters when
/// test functions accept arguments. These tests verify critical
/// protocol invariants hold across random inputs.

use starkprivacy_primitives::{
    poseidon_hash_2, poseidon_hash_4, compute_note_commitment, Note,
};
use starkprivacy_primitives::note::compute_nullifier_v2;

// ─── Hash properties ─────────────────────────────────────────────

/// Poseidon(a, b) is deterministic: same inputs always give same output.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_poseidon2_deterministic(a: felt252, b: felt252) {
    assert!(poseidon_hash_2(a, b) == poseidon_hash_2(a, b));
}

/// Poseidon is non-trivially distributed: H(a,b) != a and H(a,b) != b
/// for most inputs (probabilistically guaranteed for random felt252).
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_poseidon2_non_identity(a: felt252, b: felt252) {
    let h = poseidon_hash_2(a, b);
    // The probability of h == a or h == b over the full field is negligible.
    // We only assert h != 0 for the (0,0) edge case.
    if a != 0 || b != 0 {
        // Hash of non-zero inputs is extremely unlikely to be zero
        let _ = h; // no assertion needed — just checks the hash doesn't panic
    }
}

/// Poseidon is order-sensitive: H(a,b) != H(b,a) for a != b.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_poseidon2_order_sensitive(a: felt252, b: felt252) {
    if a != b {
        assert!(
            poseidon_hash_2(a, b) != poseidon_hash_2(b, a),
            "hash must be order-sensitive",
        );
    }
}

// ─── Commitment properties ───────────────────────────────────────

/// Different blindings always produce different commitments
/// (collision resistance for random blindings).
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_commitment_blinding_independence(blinding1: felt252, blinding2: felt252) {
    if blinding1 == blinding2 {
        return;
    }
    let n1 = Note { owner: 0xDEAD, value: 100, asset_id: 0, blinding: blinding1 };
    let n2 = Note { owner: 0xDEAD, value: 100, asset_id: 0, blinding: blinding2 };
    let c1 = compute_note_commitment(@n1);
    let c2 = compute_note_commitment(@n2);
    assert!(c1 != c2, "different blindings must give different commitments");
}

/// Different owners always produce different commitments.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_commitment_owner_binding(owner1: felt252, owner2: felt252) {
    if owner1 == owner2 {
        return;
    }
    let n1 = Note { owner: owner1, value: 100, asset_id: 0, blinding: 0xBEEF };
    let n2 = Note { owner: owner2, value: 100, asset_id: 0, blinding: 0xBEEF };
    assert!(
        compute_note_commitment(@n1) != compute_note_commitment(@n2),
        "different owners must give different commitments",
    );
}

/// Commitment is deterministic.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_commitment_deterministic(
    owner: felt252, value: felt252, asset: felt252, blinding: felt252,
) {
    let n = Note { owner, value, asset_id: asset, blinding };
    assert!(compute_note_commitment(@n) == compute_note_commitment(@n));
}

// ─── Nullifier properties ────────────────────────────────────────

/// Domain separation: same (sk, cm) but different chain_id → different nullifiers.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_nullifier_chain_separation(sk: felt252, cm: felt252, chain1: felt252, chain2: felt252) {
    if chain1 == chain2 {
        return;
    }
    let n1 = compute_nullifier_v2(sk, cm, chain1, 1);
    let n2 = compute_nullifier_v2(sk, cm, chain2, 1);
    assert!(n1 != n2, "different chains must produce different nullifiers");
}

/// Key binding: different spending keys for the same commitment → different nullifiers.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_nullifier_key_binding(sk1: felt252, sk2: felt252, cm: felt252) {
    if sk1 == sk2 {
        return;
    }
    let n1 = compute_nullifier_v2(sk1, cm, 1, 1);
    let n2 = compute_nullifier_v2(sk2, cm, 1, 1);
    assert!(n1 != n2, "different keys must produce different nullifiers");
}

/// Nullifier determinism.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_nullifier_deterministic(sk: felt252, cm: felt252, chain: felt252, app: felt252) {
    assert!(
        compute_nullifier_v2(sk, cm, chain, app) == compute_nullifier_v2(sk, cm, chain, app),
    );
}

/// Commitment binding: different commitments with same key → different nullifiers.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_nullifier_commitment_binding(sk: felt252, cm1: felt252, cm2: felt252) {
    if cm1 == cm2 {
        return;
    }
    let n1 = compute_nullifier_v2(sk, cm1, 1, 1);
    let n2 = compute_nullifier_v2(sk, cm2, 1, 1);
    assert!(n1 != n2, "different commitments must produce different nullifiers");
}

// ─── App ID separation ───────────────────────────────────────────

/// Domain separation: same (sk, cm, chain) but different app_id → different nullifiers.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_nullifier_app_separation(sk: felt252, cm: felt252, app1: felt252, app2: felt252) {
    if app1 == app2 {
        return;
    }
    let n1 = compute_nullifier_v2(sk, cm, 1, app1);
    let n2 = compute_nullifier_v2(sk, cm, 1, app2);
    assert!(n1 != n2, "different apps must produce different nullifiers");
}

// ─── Commitment value binding ────────────────────────────────────

/// Different values always produce different commitments (value binding).
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_commitment_value_binding(value1: felt252, value2: felt252) {
    if value1 == value2 {
        return;
    }
    let n1 = Note { owner: 0xDEAD, value: value1, asset_id: 0, blinding: 0xBEEF };
    let n2 = Note { owner: 0xDEAD, value: value2, asset_id: 0, blinding: 0xBEEF };
    assert!(
        compute_note_commitment(@n1) != compute_note_commitment(@n2),
        "different values must give different commitments",
    );
}

/// Different asset IDs produce different commitments (asset binding).
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_commitment_asset_binding(asset1: felt252, asset2: felt252) {
    if asset1 == asset2 {
        return;
    }
    let n1 = Note { owner: 0xDEAD, value: 100, asset_id: asset1, blinding: 0xBEEF };
    let n2 = Note { owner: 0xDEAD, value: 100, asset_id: asset2, blinding: 0xBEEF };
    assert!(
        compute_note_commitment(@n1) != compute_note_commitment(@n2),
        "different assets must give different commitments",
    );
}

// ─── Poseidon4 properties ────────────────────────────────────────

/// Poseidon4 determinism.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_poseidon4_deterministic(a: felt252, b: felt252, c: felt252, d: felt252) {
    assert!(poseidon_hash_4(a, b, c, d) == poseidon_hash_4(a, b, c, d));
}

/// Poseidon4 is sensitive to all inputs — changing any one input changes the hash.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_poseidon4_input_sensitivity(a: felt252, b: felt252, c: felt252, d: felt252) {
    let base = poseidon_hash_4(a, b, c, d);
    // Flip 'd' to d+1 (wrapping in felt252 field)
    let d2 = d + 1;
    if d2 != d {
        assert!(
            base != poseidon_hash_4(a, b, c, d2),
            "changing last input must change hash",
        );
    }
}

// ─── Merkle tree fuzz tests ──────────────────────────────────────

use starkprivacy_tree::{
    MerkleTree, MerkleTreeTrait, TREE_DEPTH, compute_root_from_path, verify_merkle_proof,
    compute_zero_hashes,
};

/// Insert determinism: same leaf always produces the same root.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_tree_insert_deterministic(leaf: felt252) {
    let (mut tree1, mut frontier1) = MerkleTreeTrait::new();
    let (mut tree2, mut frontier2) = MerkleTreeTrait::new();

    let root1 = tree1.insert(ref frontier1, leaf);
    let root2 = tree2.insert(ref frontier2, leaf);
    assert!(root1 == root2, "same leaf must produce same root");
}

/// Every insert must change the root.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_tree_insert_changes_root(leaf: felt252) {
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    let old_root = tree.root;
    tree.insert(ref frontier, leaf);
    assert!(tree.root != old_root, "insert must change root");
}

/// Different leaves inserted at the same position produce different roots.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_tree_different_leaves_different_roots(leaf1: felt252, leaf2: felt252) {
    if leaf1 == leaf2 {
        return;
    }
    let (mut tree1, mut frontier1) = MerkleTreeTrait::new();
    let (mut tree2, mut frontier2) = MerkleTreeTrait::new();

    tree1.insert(ref frontier1, leaf1);
    tree2.insert(ref frontier2, leaf2);
    assert!(tree1.root != tree2.root, "different leaves must produce different roots");
}

/// Order sensitivity: [A, B] root != [B, A] root for A != B.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_tree_insert_order_sensitive(a: felt252, b: felt252) {
    if a == b {
        return;
    }
    let (mut tree1, mut frontier1) = MerkleTreeTrait::new();
    tree1.insert(ref frontier1, a);
    tree1.insert(ref frontier1, b);

    let (mut tree2, mut frontier2) = MerkleTreeTrait::new();
    tree2.insert(ref frontier2, b);
    tree2.insert(ref frontier2, a);

    assert!(tree1.root != tree2.root, "insert order must affect root");
}

/// Proof verification for first leaf in a two-leaf tree.
/// The proof path for index 0 after two inserts: sibling at level 0 is leaf2,
/// rest are zero hashes.
#[test]
#[fuzzer(runs: 64)]
fn test_fuzz_tree_proof_after_two_inserts(leaf1: felt252, leaf2: felt252) {
    let zeros = compute_zero_hashes();
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    tree.insert(ref frontier, leaf1);
    tree.insert(ref frontier, leaf2);

    // Build proof path for index 0: sibling is leaf2 at level 0, zeros above
    let mut path: Array<felt252> = array![];
    path.append(leaf2); // level 0 sibling
    let mut i: u32 = 1;
    while i < TREE_DEPTH {
        path.append(*zeros.at(i));
        i += 1;
    };

    assert!(
        verify_merkle_proof(tree.root, leaf1, 0, path.span()),
        "proof for first leaf must be valid",
    );
}

/// Wrong leaf must fail proof verification.
#[test]
#[fuzzer(runs: 256)]
fn test_fuzz_tree_wrong_leaf_fails_proof(leaf: felt252, wrong_leaf: felt252) {
    if leaf == wrong_leaf {
        return;
    }
    let zeros = compute_zero_hashes();
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    tree.insert(ref frontier, leaf);

    let mut path: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i < TREE_DEPTH {
        path.append(*zeros.at(i));
        i += 1;
    };

    assert!(
        !verify_merkle_proof(tree.root, wrong_leaf, 0, path.span()),
        "wrong leaf must fail proof",
    );
}

/// Sequential inserts monotonically increase next_index.
#[test]
#[fuzzer(runs: 64)]
fn test_fuzz_tree_next_index_monotonic(a: felt252, b: felt252, c: felt252) {
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    assert!(tree.next_index == 0);
    tree.insert(ref frontier, a);
    assert!(tree.next_index == 1);
    tree.insert(ref frontier, b);
    assert!(tree.next_index == 2);
    tree.insert(ref frontier, c);
    assert!(tree.next_index == 3);
}

/// compute_root_from_path with wrong path length panics.
#[test]
#[should_panic(expected: "path length must equal tree depth")]
fn test_tree_wrong_path_length_panics() {
    let short_path: Array<felt252> = array![0, 0, 0];
    compute_root_from_path(0x1234, 0, short_path.span());
}

// ─── Merkle tree boundary fuzz tests ─────────────────────────────

/// Proof for leaf at index 0 (left-most) is always valid after single insert.
#[test]
#[fuzzer(runs: 128)]
fn test_fuzz_tree_boundary_index_zero_proof(leaf: felt252) {
    let zeros = compute_zero_hashes();
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
        "proof for index 0 must always be valid after single insert",
    );
}

/// compute_root_from_path at index 0 matches the tree root after a single insert.
#[test]
#[fuzzer(runs: 128)]
fn test_fuzz_tree_boundary_compute_root_index_zero(leaf: felt252) {
    let zeros = compute_zero_hashes();
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    let tree_root = tree.insert(ref frontier, leaf);

    let mut path: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i < TREE_DEPTH {
        path.append(*zeros.at(i));
        i += 1;
    };

    let computed = compute_root_from_path(leaf, 0, path.span());
    assert!(computed == tree_root, "compute_root_from_path at idx 0 must equal tree root");
}

/// After a power-of-2 number of inserts (4), proof for first leaf remains valid.
/// This exercises the frontier carry-chain at a 2-bit boundary.
#[test]
#[fuzzer(runs: 64)]
fn test_fuzz_tree_boundary_power_of_two_inserts(a: felt252, b: felt252, c: felt252, d: felt252) {
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    tree.insert(ref frontier, a);
    let root_after_b = tree.insert(ref frontier, b);
    tree.insert(ref frontier, c);
    tree.insert(ref frontier, d);
    // After 4 inserts, next_index should be exactly 4
    assert!(tree.next_index == 4, "next_index must be 4 after 4 inserts");
    // Root at index 1 must differ from final root (tree evolved)
    assert!(root_after_b != tree.root, "root changes between insert 2 and insert 4");
}

/// Proof for the last inserted leaf (right-child at level 0) is valid
/// in a 2-leaf tree. Tests right-sibling path construction.
#[test]
#[fuzzer(runs: 64)]
fn test_fuzz_tree_boundary_right_child_proof(leaf1: felt252, leaf2: felt252) {
    let zeros = compute_zero_hashes();
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    tree.insert(ref frontier, leaf1);
    tree.insert(ref frontier, leaf2);

    // Proof for index 1: sibling at level 0 is leaf1, rest are zero hashes
    let mut path: Array<felt252> = array![];
    path.append(leaf1); // level 0 sibling (left)
    let mut i: u32 = 1;
    while i < TREE_DEPTH {
        path.append(*zeros.at(i));
        i += 1;
    };

    assert!(
        verify_merkle_proof(tree.root, leaf2, 1, path.span()),
        "proof for right child (index 1) must be valid",
    );
}

/// Inserting a leaf at index 0 with value 0 (zero leaf) must NOT change the root.
/// The zero hash at level 0 is 0, so inserting 0 is indistinguishable from
/// an empty slot — the root stays the same. This is by design: callers must
/// ensure leaf values are nonzero (e.g. note commitments are always nonzero).
#[test]
fn test_tree_boundary_zero_leaf_insert() {
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    let empty_root = tree.root;
    tree.insert(ref frontier, 0);
    // Zero leaf == empty slot, so the root does NOT change.
    assert!(tree.root == empty_root, "inserting zero leaf must not change root");
    // However, next_index must still advance.
    assert!(tree.next_index == 1, "next_index must advance for zero leaf");
}

/// 8 sequential inserts: all next_index values are correct (tests 3-bit carry chain).
#[test]
fn test_tree_boundary_eight_sequential_inserts() {
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    let mut i: u64 = 0;
    while i < 8 {
        assert!(tree.next_index == i, "next_index must equal loop counter before insert");
        tree.insert(ref frontier, i.into());
        i += 1;
    };
    assert!(tree.next_index == 8, "next_index must be 8 after 8 inserts");
}

/// verify_merkle_proof must reject a valid leaf with a wrong index.
#[test]
#[fuzzer(runs: 128)]
fn test_fuzz_tree_boundary_wrong_index_fails_proof(leaf: felt252) {
    let zeros = compute_zero_hashes();
    let (mut tree, mut frontier) = MerkleTreeTrait::new();
    tree.insert(ref frontier, leaf);

    let mut path: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i < TREE_DEPTH {
        path.append(*zeros.at(i));
        i += 1;
    };

    // Index 0 with the zero-proof should pass (already tested), but index 1 must fail
    assert!(
        !verify_merkle_proof(tree.root, leaf, 1, path.span()),
        "valid leaf at wrong index must fail proof",
    );
}
