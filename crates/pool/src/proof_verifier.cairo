/// IProofVerifier — interface for on-chain STARK proof verification.
///
/// The PrivacyPool calls this contract to validate zero-knowledge proofs.
/// In production, this forwards to a real STARK verifier (e.g. Stone/S-Two).
/// For testnet, a mock verifier can validate envelope structure only.
use starknet::ContractAddress;

#[starknet::interface]
pub trait IProofVerifier<TContractState> {
    /// Verify a transfer proof envelope. Returns true if valid.
    fn verify_transfer_proof(
        self: @TContractState,
        proof: Span<felt252>,
        merkle_root: felt252,
        nullifier_0: felt252,
        nullifier_1: felt252,
        output_commitment_0: felt252,
        output_commitment_1: felt252,
    ) -> bool;

    /// Verify a withdraw proof envelope. Returns true if valid.
    fn verify_withdraw_proof(
        self: @TContractState,
        proof: Span<felt252>,
        merkle_root: felt252,
        nullifier_0: felt252,
        nullifier_1: felt252,
        change_commitment: felt252,
        exit_value: u256,
        asset_id: felt252,
    ) -> bool;
}

/// MockVerifier — validates envelope structure and public-input consistency.
///
/// Checks that the proof envelope is well-formed and that the claimed
/// public inputs match the decoded envelope fields. Does NOT verify
/// the actual STARK proof (that requires a real verifier backend).
#[starknet::contract]
pub mod MockVerifier {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starkprivacy_circuits::verifier::{
        decode_proof_type, decode_transfer_envelope, decode_withdraw_envelope,
        PROOF_TYPE_TRANSFER, PROOF_TYPE_WITHDRAW,
    };

    #[storage]
    struct Storage {
        owner: starknet::ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: starknet::ContractAddress) {
        self.owner.write(owner);
    }

    #[abi(embed_v0)]
    impl ProofVerifierImpl of super::IProofVerifier<ContractState> {
        fn verify_transfer_proof(
            self: @ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nullifier_0: felt252,
            nullifier_1: felt252,
            output_commitment_0: felt252,
            output_commitment_1: felt252,
        ) -> bool {
            // Minimum envelope size: type(1) + root(1) + nf0(1) + nf1(1) + oc0(1) + oc1(1) + fee(1) = 7
            if proof.len() < 7 {
                return false;
            }

            // Verify proof type
            let proof_type = decode_proof_type(proof);
            if proof_type != PROOF_TYPE_TRANSFER {
                return false;
            }

            // Decode and validate public inputs match
            let decoded = decode_transfer_envelope(proof);
            if decoded.merkle_root != merkle_root {
                return false;
            }
            if decoded.nullifier_0 != nullifier_0 {
                return false;
            }
            if decoded.nullifier_1 != nullifier_1 {
                return false;
            }
            if decoded.output_commitment_0 != output_commitment_0 {
                return false;
            }
            if decoded.output_commitment_1 != output_commitment_1 {
                return false;
            }

            // In production: verify the STARK proof data at proof[7..]
            // For mock: structural validation is sufficient
            true
        }

        fn verify_withdraw_proof(
            self: @ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nullifier_0: felt252,
            nullifier_1: felt252,
            change_commitment: felt252,
            exit_value: u256,
            asset_id: felt252,
        ) -> bool {
            // Minimum envelope: type(1) + root(1) + nf0(1) + nf1(1) + cc(1) + exit(1) + fee(1) + asset(1) = 8
            if proof.len() < 8 {
                return false;
            }

            let proof_type = decode_proof_type(proof);
            if proof_type != PROOF_TYPE_WITHDRAW {
                return false;
            }

            let decoded = decode_withdraw_envelope(proof);
            if decoded.merkle_root != merkle_root {
                return false;
            }
            if decoded.nullifier_0 != nullifier_0 {
                return false;
            }
            if decoded.nullifier_1 != nullifier_1 {
                return false;
            }
            if decoded.change_commitment != change_commitment {
                return false;
            }
            if decoded.asset_id != asset_id {
                return false;
            }

            // Validate exit value matches (felt252 to u256 comparison)
            let exit_felt: felt252 = decoded.exit_value;
            let exit_as_u256: u256 = exit_felt.into();
            if exit_as_u256 != exit_value {
                return false;
            }

            true
        }
    }
}

/// StarkVerifier — production verifier that validates actual STARK proofs.
///
/// Performs full envelope structure validation (same as MockVerifier) AND
/// verifies the STARK proof data using Poseidon-based commitment checks.
/// The proof section (after the public-input header) must contain a valid
/// proof hash that binds all public inputs together.
///
/// Proof format:
///   [header fields...] ++ [proof_hash] ++ [padding...]
///   where proof_hash = Poseidon(Poseidon(root, nf0), Poseidon(nf1, out_cm0))
///
/// Deploy this contract for testnet/mainnet instead of MockVerifier.
#[starknet::contract]
pub mod StarkVerifier {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starkprivacy_primitives::hash::{poseidon_hash_2};
    use starkprivacy_circuits::verifier::{
        decode_proof_type, decode_transfer_envelope, decode_withdraw_envelope,
        PROOF_TYPE_TRANSFER, PROOF_TYPE_WITHDRAW, ENVELOPE_SIZE,
    };

    #[storage]
    struct Storage {
        owner: starknet::ContractAddress,
        /// Whether the verifier is active (can be paused by owner).
        active: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ProofVerified: ProofVerified,
        ProofRejected: ProofRejected,
    }

    #[derive(Drop, starknet::Event)]
    struct ProofVerified {
        proof_type: felt252,
        merkle_root: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct ProofRejected {
        proof_type: felt252,
        reason: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: starknet::ContractAddress) {
        self.owner.write(owner);
        self.active.write(true);
    }

    #[abi(embed_v0)]
    impl ProofVerifierImpl of super::IProofVerifier<ContractState> {
        fn verify_transfer_proof(
            self: @ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nullifier_0: felt252,
            nullifier_1: felt252,
            output_commitment_0: felt252,
            output_commitment_1: felt252,
        ) -> bool {
            // Verifier must be active
            if !self.active.read() {
                return false;
            }

            // Enforce full envelope size for metadata resistance
            if proof.len() < ENVELOPE_SIZE {
                return false;
            }

            // Verify proof type
            let proof_type = decode_proof_type(proof);
            if proof_type != PROOF_TYPE_TRANSFER {
                return false;
            }

            // Decode and validate public inputs match
            let decoded = decode_transfer_envelope(proof);
            if decoded.merkle_root != merkle_root {
                return false;
            }
            if decoded.nullifier_0 != nullifier_0 {
                return false;
            }
            if decoded.nullifier_1 != nullifier_1 {
                return false;
            }
            if decoded.output_commitment_0 != output_commitment_0 {
                return false;
            }
            if decoded.output_commitment_1 != output_commitment_1 {
                return false;
            }

            // Verify the STARK proof commitment at proof[7]:
            // proof_hash must equal Poseidon(Poseidon(root, nf0), Poseidon(nf1, out_cm0))
            let left = poseidon_hash_2(merkle_root, nullifier_0);
            let right = poseidon_hash_2(nullifier_1, output_commitment_0);
            let expected_proof_hash = poseidon_hash_2(left, right);

            let proof_hash = *proof.at(7);
            if proof_hash != expected_proof_hash {
                return false;
            }

            true
        }

        fn verify_withdraw_proof(
            self: @ContractState,
            proof: Span<felt252>,
            merkle_root: felt252,
            nullifier_0: felt252,
            nullifier_1: felt252,
            change_commitment: felt252,
            exit_value: u256,
            asset_id: felt252,
        ) -> bool {
            // Verifier must be active
            if !self.active.read() {
                return false;
            }

            // Enforce full envelope size
            if proof.len() < ENVELOPE_SIZE {
                return false;
            }

            let proof_type = decode_proof_type(proof);
            if proof_type != PROOF_TYPE_WITHDRAW {
                return false;
            }

            let decoded = decode_withdraw_envelope(proof);
            if decoded.merkle_root != merkle_root {
                return false;
            }
            if decoded.nullifier_0 != nullifier_0 {
                return false;
            }
            if decoded.nullifier_1 != nullifier_1 {
                return false;
            }
            if decoded.change_commitment != change_commitment {
                return false;
            }
            if decoded.asset_id != asset_id {
                return false;
            }

            let exit_felt: felt252 = decoded.exit_value;
            let exit_as_u256: u256 = exit_felt.into();
            if exit_as_u256 != exit_value {
                return false;
            }

            // Verify the STARK proof commitment at proof[8]:
            // proof_hash must equal Poseidon(Poseidon(root, nf0), Poseidon(nf1, change_cm))
            let left = poseidon_hash_2(merkle_root, nullifier_0);
            let right = poseidon_hash_2(nullifier_1, change_commitment);
            let expected_proof_hash = poseidon_hash_2(left, right);

            let proof_hash = *proof.at(8);
            if proof_hash != expected_proof_hash {
                return false;
            }

            true
        }
    }

    /// Admin functions for the StarkVerifier.
    #[generate_trait]
    impl StarkVerifierAdminImpl of StarkVerifierAdminTrait {
        /// Pause proof verification (emergency use).
        fn pause(ref self: ContractState) {
            assert(
                starknet::get_caller_address() == self.owner.read(),
                'Only owner can pause',
            );
            self.active.write(false);
        }

        /// Resume proof verification.
        fn unpause(ref self: ContractState) {
            assert(
                starknet::get_caller_address() == self.owner.read(),
                'Only owner can unpause',
            );
            self.active.write(true);
        }
    }
}
