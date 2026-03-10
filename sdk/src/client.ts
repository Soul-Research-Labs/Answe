/**
 * StarkPrivacyClient — high-level interface to the StarkPrivacy protocol.
 *
 * Wraps starknet.js Provider and Account to provide:
 * - deposit() — shield tokens into the privacy pool
 * - transfer() — private 2-in-2-out transfer
 * - withdraw() — unshield tokens back to a public address
 * - balance() — compute shielded balance from local notes
 * - sync() — scan on-chain events for new notes
 */
import {
  RpcProvider,
  Account,
  Contract,
  type InvokeFunctionResponse,
} from "starknet";
import { KeyManager } from "./keys.js";
import { NoteManager, type PrivacyNote } from "./notes.js";
import { computeNoteCommitment, computeNullifier, randomFelt252 } from "./crypto.js";
import {
  PRIVACY_POOL_ABI,
  STEALTH_REGISTRY_ABI,
  L1_BRIDGE_ABI,
  EPOCH_MANAGER_ABI,
  MADARA_ADAPTER_ABI,
  type ContractAddresses,
  type Felt252,
} from "./types.js";
import {
  deriveStealthAddress,
  tryScanNote,
  type MetaAddress,
  type StealthAddress,
} from "./stealth.js";
import { type ProverBackend, LocalProver } from "./stone-prover.js";
import {
  ClientMerkleTree,
  generateTransferProof,
  generateWithdrawProof,
} from "./prover.js";
import { padEnvelope } from "./metadata.js";

export interface StarkPrivacyConfig {
  /** Starknet RPC endpoint URL. */
  rpcUrl: string;
  /** Contract addresses for the deployment. */
  contracts: ContractAddresses;
  /** Chain ID for domain separation (e.g., 'SN_SEPOLIA'). */
  chainId: Felt252;
  /** Application ID for domain separation. */
  appId: Felt252;
  /** Starknet Account (private key + address) for signing transactions. */
  account?: {
    address: string;
    privateKey: string;
  };
  /** Optional prover backend (defaults to LocalProver). */
  prover?: ProverBackend;
}

/**
 * Main client for interacting with StarkPrivacy.
 */
export class StarkPrivacyClient {
  readonly provider: RpcProvider;
  readonly keys: KeyManager;
  readonly notes: NoteManager;
  readonly prover: ProverBackend;
  readonly tree: ClientMerkleTree;
  private account?: Account;
  private poolContract?: Contract;
  private readonly config: StarkPrivacyConfig;

  constructor(config: StarkPrivacyConfig, keys: KeyManager) {
    this.config = config;
    this.provider = new RpcProvider({ nodeUrl: config.rpcUrl });
    this.keys = keys;
    this.notes = new NoteManager();
    this.prover = config.prover ?? new LocalProver();
    this.tree = new ClientMerkleTree();

    if (config.account) {
      this.account = new Account(
        this.provider,
        config.account.address,
        config.account.privateKey,
      );
      this.poolContract = new Contract(
        PRIVACY_POOL_ABI as any,
        config.contracts.pool,
        this.account,
      );
    }
  }

  /**
   * Create a client with a fresh random key pair.
   */
  static create(config: StarkPrivacyConfig): StarkPrivacyClient {
    return new StarkPrivacyClient(config, KeyManager.generate());
  }

  /**
   * Restore a client from an existing spending key.
   */
  static fromSpendingKey(
    config: StarkPrivacyConfig,
    spendingKey: Felt252,
  ): StarkPrivacyClient {
    return new StarkPrivacyClient(
      config,
      KeyManager.fromSpendingKey(spendingKey),
    );
  }

  // ─── Core Operations ──────────────────────────────────────────

  /**
   * Deposit tokens into the privacy pool.
   *
   * Creates a new note with the given value, computes its commitment,
   * and submits a deposit transaction to the PrivacyPool contract.
   *
   * @param amount - Amount to deposit (in token smallest unit).
   * @param assetId - Asset ID (0 = native token).
   * @returns The created note and transaction hash.
   */
  async deposit(
    amount: bigint,
    assetId: Felt252 = 0n,
  ): Promise<{ note: PrivacyNote; txHash: string }> {
    this.requireAccount();

    // Create a new note
    const note = this.notes.createNote(this.keys.ownerHash, amount, assetId);

    // Submit deposit to the contract
    const tx = await this.poolContract!.invoke("deposit", [
      note.commitment.toString(),
      {
        low: (amount & ((1n << 128n) - 1n)).toString(),
        high: (amount >> 128n).toString(),
      },
      assetId.toString(),
    ]);

    return { note, txHash: tx.transaction_hash };
  }

  /**
   * Execute a private transfer to another recipient.
   *
   * Selects input notes, creates output notes, and submits a transfer
   * with a mock proof (MVP — real STARK proofs in production).
   *
   * @param recipientOwnerHash - The recipient's owner hash (Poseidon(sk, 0)).
   * @param amount - Amount to send.
   * @param assetId - Asset ID.
   * @returns Output notes and transaction hash.
   */
  async transfer(
    recipientOwnerHash: Felt252,
    amount: bigint,
    assetId: Felt252 = 0n,
  ): Promise<{
    outputNotes: [PrivacyNote, PrivacyNote];
    txHash: string;
  }> {
    this.requireAccount();

    // Select input notes
    const inputs = this.notes.selectNotes(amount, assetId, this.keys.ownerHash);

    // Generate proof using the prover backend
    const result = generateTransferProof({
      spendingKey: this.keys.spendingKey,
      inputNotes: inputs,
      recipientOwnerHash,
      amount,
      assetId,
      chainId: this.config.chainId,
      appId: this.config.appId,
      tree: this.tree,
    });

    if (!result.success || !result.proof) {
      throw new Error(`Proof generation failed: ${result.error}`);
    }

    const proof = result.proof;

    // Pad proof data to ENVELOPE_SIZE for metadata resistance
    const paddedProof = padEnvelope(proof.proofData);

    // Submit transfer
    const tx = await this.poolContract!.invoke("transfer", [
      paddedProof.map((v) => v.toString()),
      proof.merkleRoot.toString(),
      proof.nullifiers.map((v) => v.toString()),
      proof.outputCommitments.map((v) => v.toString()),
    ]);

    // Mark inputs as spent
    this.notes.markSpent([inputs[0].id, inputs[1].id]);

    // Track output notes
    const totalIn = inputs[0].value + inputs[1].value;
    const change = totalIn - amount;
    const recipientNote = this.notes.createNote(recipientOwnerHash, amount, assetId);
    const changeNote = this.notes.createNote(this.keys.ownerHash, change, assetId);

    return {
      outputNotes: [recipientNote, changeNote],
      txHash: tx.transaction_hash,
    };
  }

  /**
   * Withdraw tokens from the privacy pool to a public address.
   *
   * @param recipient - Public Starknet address to receive tokens.
   * @param amount - Amount to withdraw.
   * @param assetId - Asset ID.
   * @returns Change note and transaction hash.
   */
  async withdraw(
    recipient: string,
    amount: bigint,
    assetId: Felt252 = 0n,
  ): Promise<{ changeNote: PrivacyNote | null; txHash: string }> {
    this.requireAccount();

    // Select input notes
    const inputs = this.notes.selectNotes(amount, assetId, this.keys.ownerHash);

    // Generate withdrawal proof using the prover backend
    const result = generateWithdrawProof({
      spendingKey: this.keys.spendingKey,
      inputNotes: inputs,
      exitValue: amount,
      assetId,
      chainId: this.config.chainId,
      appId: this.config.appId,
      tree: this.tree,
    });

    if (!result.success || !result.proof) {
      throw new Error(`Proof generation failed: ${result.error}`);
    }

    const proof = result.proof;

    // Pad proof data to ENVELOPE_SIZE for metadata resistance
    const paddedProof = padEnvelope(proof.proofData);

    // Submit withdrawal
    const tx = await this.poolContract!.invoke("withdraw", [
      paddedProof.map((v) => v.toString()),
      proof.merkleRoot.toString(),
      proof.nullifiers.map((v) => v.toString()),
      proof.outputCommitments[0]?.toString() ?? "0",
      recipient,
      {
        low: (amount & ((1n << 128n) - 1n)).toString(),
        high: (amount >> 128n).toString(),
      },
      assetId.toString(),
    ]);

    // Mark inputs as spent
    this.notes.markSpent([inputs[0].id, inputs[1].id]);

    // Track change note
    const totalIn = inputs[0].value + inputs[1].value;
    const changeAmount = totalIn - amount;
    const changeNote = changeAmount > 0n
      ? this.notes.createNote(this.keys.ownerHash, changeAmount, assetId)
      : null;

    return { changeNote, txHash: tx.transaction_hash };
  }

  // ─── View Functions ────────────────────────────────────────────

  /**
   * Get the current Merkle root from the pool contract.
   */
  async getRoot(): Promise<Felt252> {
    const poolRead = new Contract(
      PRIVACY_POOL_ABI as any,
      this.config.contracts.pool,
      this.provider,
    );
    const result = await poolRead.call("get_root");
    return BigInt(result.toString());
  }

  /**
   * Get the total number of leaves in the tree.
   */
  async getLeafCount(): Promise<bigint> {
    const poolRead = new Contract(
      PRIVACY_POOL_ABI as any,
      this.config.contracts.pool,
      this.provider,
    );
    const result = await poolRead.call("get_leaf_count");
    return BigInt(result.toString());
  }

  /**
   * Check if a nullifier has been spent on-chain.
   */
  async isNullifierSpent(nullifier: Felt252): Promise<boolean> {
    const poolRead = new Contract(
      PRIVACY_POOL_ABI as any,
      this.config.contracts.pool,
      this.provider,
    );
    const result = await poolRead.call("is_nullifier_spent", [
      nullifier.toString(),
    ]);
    return BigInt(result.toString()) === 1n;
  }

  /**
   * Get the shielded balance from local note tracking.
   */
  getBalance(assetId: Felt252 = 0n): bigint {
    return this.notes.getBalance(assetId);
  }

  /**
   * Get an overview of the user's notes.
   */
  getNoteStats(): { unspent: number; spent: number; pending: number } {
    return this.notes.getStats();
  }

  // ─── Stealth Address Operations ─────────────────────────────────

  /**
   * Register a stealth meta-address on the StealthRegistry.
   * This publishes your spending + viewing public keys so others
   * can send you stealth payments.
   */
  async registerStealthMetaAddress(
    spendingPubKey: Felt252,
    viewingPubKey: Felt252,
  ): Promise<string> {
    this.requireAccount();
    this.requireContract("stealthRegistry");

    const registry = new Contract(
      STEALTH_REGISTRY_ABI as any,
      this.config.contracts.stealthRegistry!,
      this.account!,
    );
    const tx = await registry.invoke("register_meta_address", [
      spendingPubKey.toString(),
      viewingPubKey.toString(),
    ]);
    return tx.transaction_hash;
  }

  /**
   * Send a stealth payment to a recipient.
   * Derives a one-time stealth address and publishes the ephemeral key.
   */
  async stealthSend(
    recipientMeta: MetaAddress,
    amount: bigint,
    assetId: Felt252 = 0n,
  ): Promise<{
    note: PrivacyNote;
    stealth: StealthAddress;
    txHash: string;
  }> {
    this.requireAccount();

    // Derive stealth address
    const stealth = deriveStealthAddress(recipientMeta);

    // Create note with stealth owner
    const note = this.notes.createNote(stealth.ownerHash, amount, assetId);

    // Deposit into pool
    const tx = await this.poolContract!.invoke("deposit", [
      note.commitment.toString(),
      {
        low: (amount & ((1n << 128n) - 1n)).toString(),
        high: (amount >> 128n).toString(),
      },
      assetId.toString(),
    ]);

    // Publish ephemeral key on stealth registry (if configured)
    if (this.config.contracts.stealthRegistry) {
      const registry = new Contract(
        STEALTH_REGISTRY_ABI as any,
        this.config.contracts.stealthRegistry,
        this.account!,
      );
      await registry.invoke("publish_ephemeral_key", [
        stealth.ephemeralPubKey.toString(),
        [],
        note.commitment.toString(),
        "0",
      ]);
    }

    return { note, stealth, txHash: tx.transaction_hash };
  }

  /**
   * Scan for incoming stealth payments.
   * Checks ephemeral keys on the registry to find notes addressed to us.
   */
  async scanStealthNotes(
    spendingPubKey: Felt252,
    fromIndex: number = 0,
  ): Promise<
    { index: number; ephemeralPubKey: Felt252; commitment: Felt252 }[]
  > {
    this.requireContract("stealthRegistry");

    const registry = new Contract(
      STEALTH_REGISTRY_ABI as any,
      this.config.contracts.stealthRegistry!,
      this.provider,
    );

    const countResult = await registry.call("get_ephemeral_count");
    const count = Number(BigInt(countResult.toString()));
    const found: {
      index: number;
      ephemeralPubKey: Felt252;
      commitment: Felt252;
    }[] = [];

    for (let i = fromIndex; i < count; i++) {
      const result = await registry.call("get_ephemeral_at", [i.toString()]);
      const [ephPubStr, commitmentStr] = Array.isArray(result)
        ? result
        : [result];
      const ephPub = BigInt(ephPubStr.toString());
      const commitment = BigInt(commitmentStr.toString());

      // Trial scan
      if (
        tryScanNote(ephPub, this.keys.viewingKey, spendingPubKey, commitment)
      ) {
        found.push({
          index: i,
          ephemeralPubKey: ephPub,
          commitment,
        });
      }
    }

    return found;
  }

  // ─── Bridge Operations ─────────────────────────────────────────

  /**
   * Bridge tokens from L2 to L1.
   */
  async bridgeToL1(
    commitment: Felt252,
    l1Recipient: Felt252,
    amount: bigint,
    assetId: Felt252 = 0n,
  ): Promise<string> {
    this.requireAccount();
    this.requireContract("l1Bridge");

    const bridge = new Contract(
      L1_BRIDGE_ABI as any,
      this.config.contracts.l1Bridge!,
      this.account!,
    );
    const tx = await bridge.invoke("bridge_to_l1", [
      commitment.toString(),
      l1Recipient.toString(),
      {
        low: (amount & ((1n << 128n) - 1n)).toString(),
        high: (amount >> 128n).toString(),
      },
      assetId.toString(),
    ]);
    return tx.transaction_hash;
  }

  /**
   * Get the current epoch number from the EpochManager.
   */
  async getCurrentEpoch(): Promise<bigint> {
    this.requireContract("epochManager");

    const epochMgr = new Contract(
      EPOCH_MANAGER_ABI as any,
      this.config.contracts.epochManager!,
      this.provider,
    );
    const result = await epochMgr.call("get_current_epoch");
    return BigInt(result.toString());
  }

  /**
   * Get the nullifier root for a finalized epoch.
   */
  async getEpochRoot(epoch: bigint): Promise<Felt252> {
    this.requireContract("epochManager");

    const epochMgr = new Contract(
      EPOCH_MANAGER_ABI as any,
      this.config.contracts.epochManager!,
      this.provider,
    );
    const result = await epochMgr.call("get_epoch_root", [epoch.toString()]);
    return BigInt(result.toString());
  }

  // ─── Madara Appchain Operations ──────────────────────────────────

  /**
   * Lock a commitment for cross-chain transfer to a Madara appchain.
   */
  async lockForAppchain(
    commitment: Felt252,
    targetChainId: Felt252,
    nullifiers: [Felt252, Felt252],
    encryptedNote: Felt252,
  ): Promise<string> {
    this.requireAccount();
    this.requireContract("madaraAdapter");

    const adapter = new Contract(
      MADARA_ADAPTER_ABI as any,
      this.config.contracts.madaraAdapter!,
      this.account!,
    );
    const tx = await adapter.invoke("lock_for_appchain", [
      commitment.toString(),
      targetChainId.toString(),
      [nullifiers[0].toString(), nullifiers[1].toString()],
      encryptedNote.toString(),
    ]);
    return tx.transaction_hash;
  }

  /**
   * Receive a commitment from a peer appchain.
   */
  async receiveFromAppchain(
    commitment: Felt252,
    sourceChainId: Felt252,
    epoch: bigint,
    epochRoot: Felt252,
    encryptedNote: Felt252,
  ): Promise<string> {
    this.requireAccount();
    this.requireContract("madaraAdapter");

    const adapter = new Contract(
      MADARA_ADAPTER_ABI as any,
      this.config.contracts.madaraAdapter!,
      this.account!,
    );
    const tx = await adapter.invoke("receive_from_appchain", [
      commitment.toString(),
      sourceChainId.toString(),
      epoch.toString(),
      epochRoot.toString(),
      encryptedNote.toString(),
    ]);
    return tx.transaction_hash;
  }

  /**
   * Check if a peer chain is registered.
   */
  async isPeerRegistered(chainId: Felt252): Promise<boolean> {
    this.requireContract("madaraAdapter");

    const adapter = new Contract(
      MADARA_ADAPTER_ABI as any,
      this.config.contracts.madaraAdapter!,
      this.provider,
    );
    const result = await adapter.call("is_peer_registered", [
      chainId.toString(),
    ]);
    return BigInt(result.toString()) === 1n;
  }

  /**
   * Get the epoch root synced from a peer chain.
   */
  async getPeerEpochRoot(
    peerChainId: Felt252,
    epoch: bigint,
  ): Promise<Felt252> {
    this.requireContract("madaraAdapter");

    const adapter = new Contract(
      MADARA_ADAPTER_ABI as any,
      this.config.contracts.madaraAdapter!,
      this.provider,
    );
    const result = await adapter.call("get_peer_epoch_root", [
      peerChainId.toString(),
      epoch.toString(),
    ]);
    return BigInt(result.toString());
  }

  /**
   * Check prover backend health.
   */
  async checkProverHealth(): Promise<boolean> {
    return this.prover.healthCheck();
  }

  /**
   * Sync the local Merkle tree with on-chain commitments.
   * Call this before generating proofs to ensure Merkle paths are valid.
   *
   * @param commitments - Ordered list of on-chain leaf commitments.
   */
  syncTree(commitments: Felt252[]): void {
    this.tree.loadLeaves(commitments);
  }

  /**
   * Wait for a transaction to be accepted on-chain.
   *
   * @param txHash - Transaction hash to wait for.
   * @param retryInterval - Polling interval in ms (default 2000).
   * @param maxRetries - Maximum polling attempts (default 30).
   */
  async waitForTransaction(
    txHash: string,
    retryInterval: number = 2000,
    maxRetries: number = 30,
  ): Promise<void> {
    for (let i = 0; i < maxRetries; i++) {
      try {
        const receipt = await this.provider.getTransactionReceipt(txHash);
        const status = (receipt as any).execution_status ?? (receipt as any).status;
        if (status === "SUCCEEDED" || status === "ACCEPTED_ON_L2" || status === "ACCEPTED_ON_L1") {
          return;
        }
        if (status === "REVERTED" || status === "REJECTED") {
          throw new Error(`Transaction ${txHash} failed with status: ${status}`);
        }
      } catch (err: unknown) {
        // Transaction not yet available — keep polling
        if (err instanceof Error && (err.message.includes("failed with status") || err.message.includes("REVERTED"))) {
          throw err;
        }
      }
      await new Promise((r) => setTimeout(r, retryInterval));
    }
    throw new Error(`Transaction ${txHash} not confirmed after ${maxRetries} attempts`);
  }

  // ─── Internal ──────────────────────────────────────────────────

  private requireAccount(): void {
    if (!this.account || !this.poolContract) {
      throw new Error(
        "Account not configured. Provide account in StarkPrivacyConfig.",
      );
    }
  }

  private requireContract(name: keyof ContractAddresses): void {
    if (!this.config.contracts[name]) {
      throw new Error(`Contract address for '${name}' not configured.`);
    }
  }
}
