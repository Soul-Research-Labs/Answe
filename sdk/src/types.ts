/**
 * Shared types for the StarkPrivacy SDK.
 */

/** A felt252 value represented as a bigint (0 <= v < 2^251 + 17*2^192 + 1). */
export type Felt252 = bigint;

/** Proof data to submit on-chain. */
export interface ProofRequest {
  /** Type: 1 = transfer, 2 = withdraw. */
  proofType: 1 | 2;
  /** Merkle root the proof is valid against. */
  merkleRoot: Felt252;
  /** Nullifiers being spent. */
  nullifiers: [Felt252, Felt252];
  /** Output commitments (transfer) or change commitment (withdraw). */
  outputCommitments: Felt252[];
  /** Exit value for withdrawals. */
  exitValue?: bigint;
  /** Fee for relayer. */
  fee: bigint;
  /** Raw STARK proof data. */
  proofData: Felt252[];
}

/** Result returned by the prover. */
export interface ProofResult {
  /** Whether proof generation succeeded. */
  success: boolean;
  /** The proof request ready for on-chain submission. */
  proof?: ProofRequest;
  /** Error message if proof generation failed. */
  error?: string;
}

/** Contract addresses for the StarkPrivacy deployment. */
export interface ContractAddresses {
  /** PrivacyPool contract address. */
  pool: string;
  /** NullifierRegistry contract address (if separate). */
  nullifierRegistry?: string;
  /** StealthRegistry contract address. */
  stealthRegistry?: string;
  /** StealthAccountFactory contract address. */
  stealthFactory?: string;
  /** BridgeRouter contract address. */
  bridgeRouter?: string;
  /** L1BridgeAdapter contract address. */
  l1Bridge?: string;
  /** EpochManager contract address. */
  epochManager?: string;
  /** SanctionsOracle / ComplianceOracle address. */
  complianceOracle?: string;
  /** MadaraAdapter contract address. */
  madaraAdapter?: string;
  /** Timelock governance contract address. */
  timelock?: string;
  /** MultiSig contract address. */
  multiSig?: string;
}

/** ABIs for StarkPrivacy contracts. */
export const PRIVACY_POOL_ABI = [
  {
    name: "deposit",
    type: "function",
    inputs: [
      { name: "commitment", type: "felt" },
      { name: "amount", type: "Uint256" },
      { name: "asset_id", type: "felt" },
    ],
    outputs: [],
  },
  {
    name: "transfer",
    type: "function",
    inputs: [
      { name: "proof", type: "felt*" },
      { name: "merkle_root", type: "felt" },
      { name: "nullifiers", type: "(felt, felt)" },
      { name: "output_commitments", type: "(felt, felt)" },
    ],
    outputs: [],
  },
  {
    name: "withdraw",
    type: "function",
    inputs: [
      { name: "proof", type: "felt*" },
      { name: "merkle_root", type: "felt" },
      { name: "nullifiers", type: "(felt, felt)" },
      { name: "output_commitment", type: "felt" },
      { name: "recipient", type: "ContractAddress" },
      { name: "amount", type: "Uint256" },
      { name: "asset_id", type: "felt" },
    ],
    outputs: [],
  },
  {
    name: "get_root",
    type: "function",
    inputs: [],
    outputs: [{ name: "root", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_leaf_count",
    type: "function",
    inputs: [],
    outputs: [{ name: "count", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "is_nullifier_spent",
    type: "function",
    inputs: [{ name: "nullifier", type: "felt" }],
    outputs: [{ name: "spent", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "is_known_root",
    type: "function",
    inputs: [{ name: "root", type: "felt" }],
    outputs: [{ name: "known", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_pool_balance",
    type: "function",
    inputs: [{ name: "asset_id", type: "felt" }],
    outputs: [{ name: "balance", type: "Uint256" }],
    stateMutability: "view",
  },
] as const;
/** ABI for MadaraAdapter contract. */
export const MADARA_ADAPTER_ABI = [
  {
    name: "register_peer",
    type: "function",
    inputs: [
      { name: "peer_chain_id", type: "felt" },
      { name: "peer_adapter", type: "ContractAddress" },
    ],
    outputs: [],
  },
  {
    name: "lock_for_appchain",
    type: "function",
    inputs: [
      { name: "commitment", type: "felt" },
      { name: "target_chain_id", type: "felt" },
      { name: "nullifiers", type: "(felt, felt)" },
      { name: "encrypted_note", type: "felt" },
    ],
    outputs: [],
  },
  {
    name: "receive_from_appchain",
    type: "function",
    inputs: [
      { name: "commitment", type: "felt" },
      { name: "source_chain_id", type: "felt" },
      { name: "epoch", type: "felt" },
      { name: "epoch_root", type: "felt" },
      { name: "encrypted_note", type: "felt" },
    ],
    outputs: [],
  },
  {
    name: "sync_epoch_root",
    type: "function",
    inputs: [
      { name: "peer_chain_id", type: "felt" },
      { name: "epoch", type: "felt" },
      { name: "root", type: "felt" },
    ],
    outputs: [],
  },
  {
    name: "get_chain_id",
    type: "function",
    inputs: [],
    outputs: [{ name: "chain_id", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "is_peer_registered",
    type: "function",
    inputs: [{ name: "chain_id", type: "felt" }],
    outputs: [{ name: "registered", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_peer_epoch_root",
    type: "function",
    inputs: [
      { name: "peer_chain_id", type: "felt" },
      { name: "epoch", type: "felt" },
    ],
    outputs: [{ name: "root", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_outbound_count",
    type: "function",
    inputs: [{ name: "peer_chain_id", type: "felt" }],
    outputs: [{ name: "count", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_inbound_count",
    type: "function",
    inputs: [{ name: "peer_chain_id", type: "felt" }],
    outputs: [{ name: "count", type: "felt" }],
    stateMutability: "view",
  },
] as const; /** ABI for StealthRegistry contract. */
export const STEALTH_REGISTRY_ABI = [
  {
    name: "register_meta_address",
    type: "function",
    inputs: [
      { name: "spending_pub_x", type: "felt" },
      { name: "viewing_pub_x", type: "felt" },
    ],
    outputs: [],
  },
  {
    name: "publish_ephemeral_key",
    type: "function",
    inputs: [
      { name: "ephemeral_pub_x", type: "felt" },
      { name: "encrypted_note", type: "felt*" },
      { name: "commitment", type: "felt" },
      { name: "scan_tag", type: "felt" },
    ],
    outputs: [],
  },
  {
    name: "get_meta_address",
    type: "function",
    inputs: [{ name: "user", type: "ContractAddress" }],
    outputs: [
      { name: "spending_pub_x", type: "felt" },
      { name: "viewing_pub_x", type: "felt" },
    ],
    stateMutability: "view",
  },
  {
    name: "get_ephemeral_count",
    type: "function",
    inputs: [],
    outputs: [{ name: "count", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_ephemeral_at",
    type: "function",
    inputs: [{ name: "index", type: "felt" }],
    outputs: [
      { name: "ephemeral_pub_x", type: "felt" },
      { name: "commitment", type: "felt" },
    ],
    stateMutability: "view",
  },
  {
    name: "get_encrypted_note_at",
    type: "function",
    inputs: [{ name: "index", type: "felt" }],
    outputs: [{ name: "note", type: "felt*" }],
    stateMutability: "view",
  },
  {
    name: "get_scan_tag_at",
    type: "function",
    inputs: [{ name: "index", type: "felt" }],
    outputs: [{ name: "scan_tag", type: "felt" }],
    stateMutability: "view",
  },
] as const;

/** ABI for L1BridgeAdapter contract. */
export const L1_BRIDGE_ABI = [
  {
    name: "bridge_to_l1",
    type: "function",
    inputs: [
      { name: "commitment", type: "felt" },
      { name: "l1_recipient", type: "felt" },
      { name: "amount", type: "Uint256" },
      { name: "asset_id", type: "felt" },
    ],
    outputs: [],
  },
  {
    name: "get_outbound_count",
    type: "function",
    inputs: [],
    outputs: [{ name: "count", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_inbound_count",
    type: "function",
    inputs: [],
    outputs: [{ name: "count", type: "felt" }],
    stateMutability: "view",
  },
] as const;

/** ABI for EpochManager contract. */
export const EPOCH_MANAGER_ABI = [
  {
    name: "get_current_epoch",
    type: "function",
    inputs: [],
    outputs: [{ name: "epoch", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_epoch_root",
    type: "function",
    inputs: [{ name: "epoch", type: "felt" }],
    outputs: [{ name: "root", type: "felt" }],
    stateMutability: "view",
  },
] as const;
