/// StarkPrivacy Bridge — cross-chain privacy-preserving bridge adapters.
///
/// Implements ZAseon's ZK-Bound State Lock pattern:
/// Lock encrypted state on Chain A, unlock on Chain B with ZK proof.
///
/// Supports:
/// - L1 <-> L2 (Starknet <-> Ethereum via native messaging)
/// - L2 <-> L3 (Starknet <-> Madara appchains)
/// - Cross-EVM (via Kakarot adapter)
/// - Epoch-based nullifier synchronization across chains

pub mod router;
pub mod l1_adapter;
pub mod epoch_manager;
pub mod madara_adapter;
pub mod kakarot_adapter;

pub use router::BridgeRouter;
pub use l1_adapter::L1BridgeAdapter;
pub use epoch_manager::EpochManager;
pub use madara_adapter::MadaraAdapter;
pub use kakarot_adapter::KakarotAdapter;
