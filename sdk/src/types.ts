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
  /** Asset ID for withdrawals and relayer routing. */
  assetId?: Felt252;
  /** Recipient address for withdrawals (relayer needs this). */
  recipient?: string;
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
  /** KakarotAdapter contract address. */
  kakarotAdapter?: string;
  /** UpgradeableProxy contract address. */
  upgradeableProxy?: string;
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

/** ABI for KakarotAdapter contract. */
export const KAKAROT_ADAPTER_ABI = [
  {
    name: "evm_deposit",
    type: "function",
    inputs: [
      { name: "commitment", type: "felt" },
      { name: "amount", type: "Uint256" },
      { name: "asset_id", type: "felt" },
    ],
    outputs: [],
  },
  {
    name: "evm_transfer",
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
    name: "evm_withdraw",
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
    name: "set_gas_price_factor",
    type: "function",
    inputs: [{ name: "factor", type: "Uint256" }],
    outputs: [],
  },
  {
    name: "pause",
    type: "function",
    inputs: [],
    outputs: [],
  },
  {
    name: "unpause",
    type: "function",
    inputs: [],
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
  {
    name: "estimate_evm_fee",
    type: "function",
    inputs: [
      { name: "amount", type: "Uint256" },
      { name: "evm_gas_used", type: "Uint256" },
    ],
    outputs: [
      { name: "protocol_fee", type: "Uint256" },
      { name: "gas_premium", type: "Uint256" },
      { name: "total_fee", type: "Uint256" },
    ],
    stateMutability: "view",
  },
  {
    name: "get_pool",
    type: "function",
    inputs: [],
    outputs: [{ name: "pool", type: "ContractAddress" }],
    stateMutability: "view",
  },
  {
    name: "get_gas_price_factor",
    type: "function",
    inputs: [],
    outputs: [{ name: "factor", type: "Uint256" }],
    stateMutability: "view",
  },
] as const;

/** ABI for NullifierRegistry contract. */
export const NULLIFIER_REGISTRY_ABI = [
  {
    name: "mark_spent",
    type: "function",
    inputs: [{ name: "nullifier", type: "felt" }],
    outputs: [],
  },
  {
    name: "is_spent",
    type: "function",
    inputs: [{ name: "nullifier", type: "felt" }],
    outputs: [{ name: "spent", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "are_all_unspent",
    type: "function",
    inputs: [{ name: "nullifiers", type: "felt*" }],
    outputs: [{ name: "all_unspent", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_pool",
    type: "function",
    inputs: [],
    outputs: [{ name: "pool", type: "ContractAddress" }],
    stateMutability: "view",
  },
] as const;

/** ABI for SanctionsOracle (ComplianceOracle) contract. */
export const SANCTIONS_ORACLE_ABI = [
  {
    name: "add_sanctioned",
    type: "function",
    inputs: [{ name: "address", type: "ContractAddress" }],
    outputs: [],
  },
  {
    name: "remove_sanctioned",
    type: "function",
    inputs: [{ name: "address", type: "ContractAddress" }],
    outputs: [],
  },
  {
    name: "is_sanctioned",
    type: "function",
    inputs: [{ name: "address", type: "ContractAddress" }],
    outputs: [{ name: "sanctioned", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "check_deposit",
    type: "function",
    inputs: [
      { name: "depositor", type: "ContractAddress" },
      { name: "amount", type: "Uint256" },
      { name: "asset_id", type: "felt" },
    ],
    outputs: [{ name: "allowed", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "check_withdrawal",
    type: "function",
    inputs: [
      { name: "recipient", type: "ContractAddress" },
      { name: "amount", type: "Uint256" },
      { name: "asset_id", type: "felt" },
    ],
    outputs: [{ name: "allowed", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "check_transfer",
    type: "function",
    inputs: [
      { name: "nullifiers", type: "felt*" },
      { name: "output_commitments", type: "felt*" },
    ],
    outputs: [{ name: "allowed", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_owner",
    type: "function",
    inputs: [],
    outputs: [{ name: "owner", type: "ContractAddress" }],
    stateMutability: "view",
  },
] as const;

/** ABI for Timelock governance contract. */
export const TIMELOCK_ABI = [
  {
    name: "queue",
    type: "function",
    inputs: [
      { name: "target", type: "ContractAddress" },
      { name: "selector", type: "felt" },
      { name: "calldata_hash", type: "felt" },
      { name: "delay", type: "felt" },
    ],
    outputs: [{ name: "operation_id", type: "felt" }],
  },
  {
    name: "execute",
    type: "function",
    inputs: [
      { name: "operation_id", type: "felt" },
      { name: "calldata", type: "felt*" },
    ],
    outputs: [],
  },
  {
    name: "cancel",
    type: "function",
    inputs: [{ name: "operation_id", type: "felt" }],
    outputs: [],
  },
  {
    name: "update_min_delay",
    type: "function",
    inputs: [{ name: "new_delay", type: "felt" }],
    outputs: [],
  },
  {
    name: "get_min_delay",
    type: "function",
    inputs: [],
    outputs: [{ name: "delay", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "is_ready",
    type: "function",
    inputs: [{ name: "operation_id", type: "felt" }],
    outputs: [{ name: "ready", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "is_pending",
    type: "function",
    inputs: [{ name: "operation_id", type: "felt" }],
    outputs: [{ name: "pending", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_operation_timestamp",
    type: "function",
    inputs: [{ name: "operation_id", type: "felt" }],
    outputs: [{ name: "timestamp", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_proposer",
    type: "function",
    inputs: [],
    outputs: [{ name: "proposer", type: "ContractAddress" }],
    stateMutability: "view",
  },
] as const;

/** ABI for MultiSig (M-of-N) governance contract. */
export const MULTISIG_ABI = [
  {
    name: "propose",
    type: "function",
    inputs: [
      { name: "target", type: "ContractAddress" },
      { name: "selector", type: "felt" },
      { name: "calldata_hash", type: "felt" },
    ],
    outputs: [{ name: "proposal_id", type: "felt" }],
  },
  {
    name: "approve",
    type: "function",
    inputs: [{ name: "proposal_id", type: "felt" }],
    outputs: [],
  },
  {
    name: "revoke",
    type: "function",
    inputs: [{ name: "proposal_id", type: "felt" }],
    outputs: [],
  },
  {
    name: "forward_to_timelock",
    type: "function",
    inputs: [{ name: "proposal_id", type: "felt" }],
    outputs: [{ name: "operation_id", type: "felt" }],
  },
  {
    name: "set_timelock",
    type: "function",
    inputs: [{ name: "timelock", type: "ContractAddress" }],
    outputs: [],
  },
  {
    name: "get_timelock",
    type: "function",
    inputs: [],
    outputs: [{ name: "timelock", type: "ContractAddress" }],
    stateMutability: "view",
  },
  {
    name: "get_signer_count",
    type: "function",
    inputs: [],
    outputs: [{ name: "count", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_threshold",
    type: "function",
    inputs: [],
    outputs: [{ name: "threshold", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "get_approval_count",
    type: "function",
    inputs: [{ name: "proposal_id", type: "felt" }],
    outputs: [{ name: "count", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "is_approved",
    type: "function",
    inputs: [{ name: "proposal_id", type: "felt" }],
    outputs: [{ name: "approved", type: "felt" }],
    stateMutability: "view",
  },
  {
    name: "is_signer",
    type: "function",
    inputs: [{ name: "address", type: "ContractAddress" }],
    outputs: [{ name: "signer", type: "felt" }],
    stateMutability: "view",
  },
] as const;

/** ABI for UpgradeableProxy (UUPS) contract. */
export const UPGRADEABLE_PROXY_ABI = [
  {
    name: "upgrade",
    type: "function",
    inputs: [{ name: "new_class_hash", type: "ClassHash" }],
    outputs: [],
  },
  {
    name: "set_governor",
    type: "function",
    inputs: [{ name: "new_governor", type: "ContractAddress" }],
    outputs: [],
  },
  {
    name: "set_emergency_governor",
    type: "function",
    inputs: [{ name: "new_emergency", type: "ContractAddress" }],
    outputs: [],
  },
  {
    name: "get_implementation",
    type: "function",
    inputs: [],
    outputs: [{ name: "class_hash", type: "ClassHash" }],
    stateMutability: "view",
  },
  {
    name: "get_governor",
    type: "function",
    inputs: [],
    outputs: [{ name: "governor", type: "ContractAddress" }],
    stateMutability: "view",
  },
  {
    name: "get_emergency_governor",
    type: "function",
    inputs: [],
    outputs: [{ name: "emergency_governor", type: "ContractAddress" }],
    stateMutability: "view",
  },
  {
    name: "get_upgrade_count",
    type: "function",
    inputs: [],
    outputs: [{ name: "count", type: "felt" }],
    stateMutability: "view",
  },
] as const;
