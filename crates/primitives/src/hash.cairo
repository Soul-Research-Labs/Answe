/// Poseidon-based hashing utilities built on Cairo's native builtins.
///
/// These are thin wrappers around `core::poseidon` providing domain-separated
/// hashing — the backbone of all commitments, nullifiers, and tree nodes.
use core::poseidon::PoseidonTrait;
use core::hash::HashStateTrait;

/// Hash two felt252 values: H(a, b)
pub fn poseidon_hash_2(a: felt252, b: felt252) -> felt252 {
    let mut state = PoseidonTrait::new();
    state = state.update(a);
    state = state.update(b);
    state.finalize()
}

/// Hash three felt252 values: H(a, b, c)
pub fn poseidon_hash_3(a: felt252, b: felt252, c: felt252) -> felt252 {
    let mut state = PoseidonTrait::new();
    state = state.update(a);
    state = state.update(b);
    state = state.update(c);
    state.finalize()
}

/// Hash four felt252 values: H(a, b, c, d)
pub fn poseidon_hash_4(a: felt252, b: felt252, c: felt252, d: felt252) -> felt252 {
    let mut state = PoseidonTrait::new();
    state = state.update(a);
    state = state.update(b);
    state = state.update(c);
    state = state.update(d);
    state.finalize()
}

/// Domain-separated hash: H(domain_tag, a, b)
/// Used for nullifiers, key derivation, and cross-chain isolation.
pub fn domain_hash(domain_tag: felt252, a: felt252, b: felt252) -> felt252 {
    let mut state = PoseidonTrait::new();
    state = state.update(domain_tag);
    state = state.update(a);
    state = state.update(b);
    state.finalize()
}

#[cfg(test)]
mod tests {
    use super::{poseidon_hash_2, poseidon_hash_3, poseidon_hash_4, domain_hash};

    #[test]
    fn test_poseidon_hash_2_deterministic() {
        let h1 = poseidon_hash_2(1, 2);
        let h2 = poseidon_hash_2(1, 2);
        assert!(h1 == h2, "hash should be deterministic");
    }

    #[test]
    fn test_poseidon_hash_2_different_inputs() {
        let h1 = poseidon_hash_2(1, 2);
        let h2 = poseidon_hash_2(2, 1);
        assert!(h1 != h2, "different inputs should produce different hashes");
    }

    #[test]
    fn test_poseidon_hash_3_deterministic() {
        let h1 = poseidon_hash_3(1, 2, 3);
        let h2 = poseidon_hash_3(1, 2, 3);
        assert!(h1 == h2, "hash should be deterministic");
    }

    #[test]
    fn test_poseidon_hash_4_deterministic() {
        let h1 = poseidon_hash_4(1, 2, 3, 4);
        let h2 = poseidon_hash_4(1, 2, 3, 4);
        assert!(h1 == h2, "hash should be deterministic");
    }

    #[test]
    fn test_domain_hash_isolation() {
        let h1 = domain_hash('NULLIFIER', 100, 200);
        let h2 = domain_hash('COMMITMENT', 100, 200);
        assert!(h1 != h2, "different domains must produce different hashes");
    }

    #[test]
    fn test_poseidon_hash_nonzero() {
        let h = poseidon_hash_2(0, 0);
        assert!(h != 0, "hash of zeros should not be zero");
    }
}
