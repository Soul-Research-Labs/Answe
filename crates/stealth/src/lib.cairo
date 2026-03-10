/// StarkPrivacy Stealth — stealth address registry, encrypted notes, and account factory.
///
/// Ported from Lumora's stealth address scheme, adapted for Starknet's STARK curve.
/// Leverages Starknet's native Account Abstraction for one-time smart accounts.

pub mod registry;
pub mod encrypted_note;
pub mod factory;

pub use registry::StealthRegistry;
pub use factory::StealthAccountFactory;
pub use encrypted_note::{EncryptedNote, compute_scan_tag, pad_note_payload, NOTE_PADDED_SIZE};
