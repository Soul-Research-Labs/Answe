/// StarkPrivacy NullifierRegistry — on-chain nullifier tracking.
///
/// Tracks spent nullifiers to prevent double-spend. Uses domain-separated
/// V2 nullifiers: Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))
/// for cross-chain isolation.

pub mod registry;

pub use registry::NullifierRegistry;
