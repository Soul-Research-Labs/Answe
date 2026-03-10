/// StarkPrivacy Pool — the core privacy contract.
///
/// Combines Lumora's PrivacyPool state machine with ZAseon's policy-bound proofs.
/// Supports deposit/transfer/withdraw operations with ZK proof verification.

pub mod pool;
pub mod proof_verifier;

pub use pool::PrivacyPool;
pub use proof_verifier::MockVerifier;
