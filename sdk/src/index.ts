// @starkprivacy/sdk — Main entry point
export { StarkPrivacyClient, type StarkPrivacyConfig } from "./client.js";
export {
  KeyManager,
  type PrivacyKeyPair,
  type SpendingKey,
  type ViewingKey,
} from "./keys.js";
export {
  NoteManager,
  type PrivacyNote,
  type NoteStatus,
  saveNotesToFile,
  loadNotesFromFile,
  verifyBackup,
} from "./notes.js";
export {
  computeNoteCommitment,
  computeNullifier,
  poseidonHash2,
  poseidonHash4,
  assertValidFelt252,
} from "./crypto.js";
export {
  deriveStealthAddress,
  type StealthAddress,
  type MetaAddress,
} from "./stealth.js";
export {
  ClientMerkleTree,
  generateTransferProof,
  generateWithdrawProof,
  type TransferProofInput,
  type WithdrawProofInput,
} from "./prover.js";
export {
  Relayer,
  InMemoryJobStorage,
  type RelayerConfig,
  type RelayerJob,
  type JobStatus,
  type JobStorageAdapter,
} from "./relayer.js";
export {
  padEnvelope,
  hashEnvelope,
  wrapProof,
  createDummyEnvelope,
  buildBatch,
  relayJitter,
  ENVELOPE_SIZE,
  DEFAULT_BATCH_SIZE,
  PROOF_TYPE_TRANSFER,
  PROOF_TYPE_WITHDRAW,
  PROOF_TYPE_DUMMY,
  type ProofEnvelope,
  type Batch,
} from "./metadata.js";
export {
  EventIndexer,
  type IndexedDeposit,
  type IndexedNullifier,
  type StealthMatch,
  type ScanProgress,
} from "./indexer.js";
export {
  type ProofRequest,
  type ProofResult,
  type ContractAddresses,
  PRIVACY_POOL_ABI,
  STEALTH_REGISTRY_ABI,
  L1_BRIDGE_ABI,
  EPOCH_MANAGER_ABI,
  MADARA_ADAPTER_ABI,
  KAKAROT_ADAPTER_ABI,
  NULLIFIER_REGISTRY_ABI,
  SANCTIONS_ORACLE_ABI,
  TIMELOCK_ABI,
  MULTISIG_ABI,
  UPGRADEABLE_PROXY_ABI,
} from "./types.js";
export {
  LocalProver,
  StoneProver,
  S2Prover,
  createProver,
  type ProverBackend,
  type WitnessPayload,
  type CircuitType,
  type RemoteProverConfig,
  type RawSTARKProof,
} from "./stone-prover.js";
