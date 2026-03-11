/**
 * StarkPrivacy Relayer — accepts signed proof bundles, validates them,
 * and submits transactions on behalf of users so they never touch the
 * pool contract directly (preserving sender anonymity).
 *
 * Features:
 * - Proof validation with nullifier and fee checks
 * - Pluggable job persistence (in-memory default, database adapters available)
 * - Sequential nonce management to prevent nonce collisions
 * - Retry with exponential backoff and dead-letter queue
 * - Transaction confirmation polling
 * - Configurable pending job limits and fee thresholds
 */
import {
  RpcProvider,
  Account,
  Contract,
  type InvokeFunctionResponse,
} from "starknet";
import {
  PRIVACY_POOL_ABI,
  type ContractAddresses,
  type Felt252,
  type ProofRequest,
} from "./types.js";

// ─── Configuration ───────────────────────────────────────────────

export interface RelayerConfig {
  /** Starknet RPC endpoint. */
  rpcUrl: string;
  /** Relayer account (pays gas, earns fees). */
  account: { address: string; privateKey: string };
  /** Deployed contract addresses. */
  contracts: ContractAddresses;
  /** Minimum fee (in smallest unit) the relayer will accept. */
  minFee?: bigint;
  /** Maximum pending jobs before rejecting. */
  maxPending?: number;
  /** Maximum retry attempts for failed submissions (default 3). */
  maxRetries?: number;
  /** Optional persistent storage adapter for jobs. */
  storage?: JobStorageAdapter;
  /** Transaction confirmation timeout in ms (default 120000). */
  confirmationTimeoutMs?: number;
}

export type JobStatus = "pending" | "submitted" | "confirmed" | "failed";

export interface RelayerJob {
  id: string;
  proof: ProofRequest;
  status: JobStatus;
  txHash?: string;
  error?: string;
  retries: number;
  createdAt: number;
  updatedAt: number;
}

// ─── Job Storage Adapter ────────────────────────────────────────

/**
 * Pluggable storage adapter for relayer job persistence.
 * Implement this interface to back the relayer with a database.
 */
export interface JobStorageAdapter {
  /** Save or update a job. */
  save(job: RelayerJob): Promise<void>;
  /** Load a job by ID. */
  load(id: string): Promise<RelayerJob | undefined>;
  /** Load all jobs, optionally filtered by status. */
  loadAll(status?: JobStatus): Promise<RelayerJob[]>;
  /** Delete a job by ID. */
  delete(id: string): Promise<void>;
  /** Get the next available job ID. */
  nextId(): Promise<number>;
}

/**
 * Default in-memory storage (non-persistent — for dev/testing).
 */
export class InMemoryJobStorage implements JobStorageAdapter {
  private jobs: Map<string, RelayerJob> = new Map();
  private counter = 0;

  async save(job: RelayerJob): Promise<void> {
    this.jobs.set(job.id, { ...job });
  }

  async load(id: string): Promise<RelayerJob | undefined> {
    const job = this.jobs.get(id);
    return job ? { ...job } : undefined;
  }

  async loadAll(status?: JobStatus): Promise<RelayerJob[]> {
    const all = Array.from(this.jobs.values());
    if (!status) return all.map((j) => ({ ...j }));
    return all.filter((j) => j.status === status).map((j) => ({ ...j }));
  }

  async delete(id: string): Promise<void> {
    this.jobs.delete(id);
  }

  async nextId(): Promise<number> {
    return this.counter++;
  }
}

// ─── Relayer ─────────────────────────────────────────────────────

export class Relayer {
  private provider: RpcProvider;
  private account: Account;
  private poolContract: Contract;
  private config: RelayerConfig;
  private storage: JobStorageAdapter;
  private maxRetries: number;
  private confirmationTimeoutMs: number;
  /** Sequential processing queue to prevent nonce collisions. */
  private processingQueue: Promise<void> = Promise.resolve();
  /** Tracks the current nonce to avoid collisions in sequential submissions. */
  private currentNonce: bigint | null = null;

  constructor(config: RelayerConfig) {
    this.config = config;
    this.maxRetries = config.maxRetries ?? 3;
    this.confirmationTimeoutMs = config.confirmationTimeoutMs ?? 120_000;
    this.storage = config.storage ?? new InMemoryJobStorage();
    this.provider = new RpcProvider({ nodeUrl: config.rpcUrl });
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

  /**
   * Submit a proof bundle for relay.
   * Returns a job ID that can be polled for status.
   */
  async submit(proof: ProofRequest): Promise<string> {
    // Validate
    const error = await this.validate(proof);
    if (error) {
      throw new Error(`Validation failed: ${error}`);
    }

    const nextId = await this.storage.nextId();

    // Create job
    const job: RelayerJob = {
      id: `relay_${nextId}`,
      proof,
      status: "pending",
      retries: 0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    await this.storage.save(job);

    // Chain onto processing queue (sequential for nonce safety)
    this.processingQueue = this.processingQueue
      .then(() => this.processWithRetry(job.id))
      .catch(() => {});

    return job.id;
  }

  /**
   * Get the current status of a relay job.
   */
  async getJob(id: string): Promise<RelayerJob | undefined> {
    return this.storage.load(id);
  }

  /**
   * Get all jobs, optionally filtered by status.
   */
  async getJobs(status?: JobStatus): Promise<RelayerJob[]> {
    return this.storage.loadAll(status);
  }

  /**
   * Recover and retry all pending/submitted jobs (call on startup).
   * This allows resuming after a process restart.
   */
  async recover(): Promise<number> {
    const pending = await this.storage.loadAll("pending");
    const submitted = await this.storage.loadAll("submitted");
    const toRetry = [...pending, ...submitted];

    for (const job of toRetry) {
      this.processingQueue = this.processingQueue
        .then(() => this.processWithRetry(job.id))
        .catch(() => {});
    }

    return toRetry.length;
  }

  // ─── Validation ──────────────────────────────────────────────

  private async validate(proof: ProofRequest): Promise<string | null> {
    // Type check
    if (proof.proofType !== 1 && proof.proofType !== 2) {
      return "Invalid proof type";
    }

    // Nullifier uniqueness
    if (proof.nullifiers[0] === proof.nullifiers[1]) {
      return "Duplicate nullifiers";
    }

    // Nullifiers must be non-zero
    if (proof.nullifiers[0] === 0n || proof.nullifiers[1] === 0n) {
      return "Zero nullifier";
    }

    // Fee check
    const minFee = this.config.minFee ?? 0n;
    if (proof.fee < minFee) {
      return `Fee too low: ${proof.fee} < ${minFee}`;
    }

    // Pending limit
    const maxPending = this.config.maxPending ?? 100;
    const pendingJobs = await this.storage.loadAll("pending");
    if (pendingJobs.length >= maxPending) {
      return "Relayer queue full";
    }

    // Proof data must not be empty
    if (!proof.proofData || proof.proofData.length === 0) {
      return "Empty proof data";
    }

    // Withdraw must include recipient
    if (proof.proofType === 2 && !proof.recipient) {
      return "Withdraw proof must include recipient address";
    }

    return null;
  }

  // ─── Nonce management ──────────────────────────────────────────

  private async getNextNonce(): Promise<bigint> {
    if (this.currentNonce !== null) {
      this.currentNonce += 1n;
      return this.currentNonce;
    }
    // Fetch nonce from the network for the first transaction
    const nonce = await this.provider.getNonceForAddress(
      this.config.account.address,
    );
    this.currentNonce = BigInt(nonce);
    return this.currentNonce;
  }

  /** Reset nonce tracking (e.g., after a nonce mismatch error). */
  private resetNonce(): void {
    this.currentNonce = null;
  }

  // ─── Transaction submission with retry ─────────────────────────

  private async processWithRetry(jobId: string): Promise<void> {
    const job = await this.storage.load(jobId);
    if (!job) return;

    while (job.retries <= this.maxRetries) {
      try {
        job.status = "submitted";
        job.updatedAt = Date.now();
        await this.storage.save(job);

        let tx: InvokeFunctionResponse;

        if (job.proof.proofType === 1) {
          tx = await this.submitTransfer(job.proof);
        } else {
          tx = await this.submitWithdraw(job.proof);
        }

        job.txHash = tx.transaction_hash;
        job.updatedAt = Date.now();
        await this.storage.save(job);

        // Wait for transaction confirmation
        await this.waitForConfirmation(tx.transaction_hash);

        job.status = "confirmed";
        job.updatedAt = Date.now();
        await this.storage.save(job);
        return;
      } catch (err: unknown) {
        job.retries++;
        const msg = err instanceof Error ? err.message : String(err);

        // Reset nonce on nonce-related errors to re-fetch from network
        if (msg.includes("nonce") || msg.includes("Nonce")) {
          this.resetNonce();
        }

        if (job.retries > this.maxRetries) {
          job.status = "failed";
          job.error = msg;
          job.updatedAt = Date.now();
          await this.storage.save(job);
          return;
        }

        // Exponential backoff: 1s, 2s, 4s, 8s...
        const backoffMs = 1000 * 2 ** (job.retries - 1);
        await new Promise((r) => setTimeout(r, backoffMs));
        job.status = "pending";
        job.updatedAt = Date.now();
        await this.storage.save(job);
      }
    }
  }

  private async waitForConfirmation(txHash: string): Promise<void> {
    const deadline = Date.now() + this.confirmationTimeoutMs;
    const pollInterval = 2000;

    while (Date.now() < deadline) {
      try {
        const receipt = await this.provider.getTransactionReceipt(txHash);
        const status =
          (receipt as any).execution_status ?? (receipt as any).status;
        if (
          status === "SUCCEEDED" ||
          status === "ACCEPTED_ON_L2" ||
          status === "ACCEPTED_ON_L1"
        ) {
          return;
        }
        if (status === "REVERTED" || status === "REJECTED") {
          throw new Error(`Transaction ${txHash} failed: ${status}`);
        }
      } catch (err: unknown) {
        if (
          err instanceof Error &&
          (err.message.includes("failed") || err.message.includes("REVERTED"))
        ) {
          throw err;
        }
        // Transaction not yet available — keep polling
      }
      await new Promise((r) => setTimeout(r, pollInterval));
    }
    throw new Error(
      `Transaction ${txHash} not confirmed within ${this.confirmationTimeoutMs}ms`,
    );
  }

  private async submitTransfer(
    proof: ProofRequest,
  ): Promise<InvokeFunctionResponse> {
    return this.poolContract.invoke("transfer", [
      proof.proofData.map((v) => v.toString()),
      proof.merkleRoot.toString(),
      proof.nullifiers.map((v) => v.toString()),
      proof.outputCommitments.map((v) => v.toString()),
    ]);
  }

  private async submitWithdraw(
    proof: ProofRequest,
  ): Promise<InvokeFunctionResponse> {
    const exitValue = proof.exitValue ?? 0n;
    const recipient = proof.recipient ?? "0";
    return this.poolContract.invoke("withdraw", [
      proof.proofData.map((v) => v.toString()),
      proof.merkleRoot.toString(),
      proof.nullifiers.map((v) => v.toString()),
      proof.outputCommitments[0]?.toString() ?? "0",
      recipient,
      {
        low: (exitValue & ((1n << 128n) - 1n)).toString(),
        high: (exitValue >> 128n).toString(),
      },
      "0", // assetId
    ]);
  }
}
