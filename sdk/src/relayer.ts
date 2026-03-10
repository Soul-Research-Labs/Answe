/**
 * StarkPrivacy Relayer — accepts signed proof bundles, validates them,
 * and submits transactions on behalf of users so they never touch the
 * pool contract directly (preserving sender anonymity).
 *
 * This is a scaffold; production would add:
 * - Persistent job queue (Redis / SQS)
 * - Fee market / gas estimation
 * - Rate limiting & anti-spam
 * - Nonce management & retry logic
 * - Monitoring / alerting
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
}

export type JobStatus = "pending" | "submitted" | "confirmed" | "failed";

export interface RelayerJob {
  id: string;
  proof: ProofRequest;
  status: JobStatus;
  txHash?: string;
  error?: string;
  createdAt: number;
  updatedAt: number;
}

// ─── Relayer ─────────────────────────────────────────────────────

export class Relayer {
  private provider: RpcProvider;
  private account: Account;
  private poolContract: Contract;
  private config: RelayerConfig;
  private jobs: Map<string, RelayerJob> = new Map();
  private nextId = 0;

  constructor(config: RelayerConfig) {
    this.config = config;
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
    const error = this.validate(proof);
    if (error) {
      throw new Error(`Validation failed: ${error}`);
    }

    // Create job
    const job: RelayerJob = {
      id: `relay_${this.nextId++}`,
      proof,
      status: "pending",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    this.jobs.set(job.id, job);

    // Process asynchronously
    this.process(job).catch(() => {});
    return job.id;
  }

  /**
   * Get the current status of a relay job.
   */
  getJob(id: string): RelayerJob | undefined {
    return this.jobs.get(id);
  }

  /**
   * Get all jobs, optionally filtered by status.
   */
  getJobs(status?: JobStatus): RelayerJob[] {
    const all = Array.from(this.jobs.values());
    if (!status) return all;
    return all.filter((j) => j.status === status);
  }

  // ─── Validation ──────────────────────────────────────────────

  private validate(proof: ProofRequest): string | null {
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
    const pendingCount = this.getJobs("pending").length;
    if (pendingCount >= maxPending) {
      return "Relayer queue full";
    }

    // Proof data must not be empty
    if (!proof.proofData || proof.proofData.length === 0) {
      return "Empty proof data";
    }

    return null;
  }

  // ─── Transaction submission ────────────────────────────────────

  private async process(job: RelayerJob): Promise<void> {
    try {
      job.status = "submitted";
      job.updatedAt = Date.now();

      let tx: InvokeFunctionResponse;

      if (job.proof.proofType === 1) {
        tx = await this.submitTransfer(job.proof);
      } else {
        tx = await this.submitWithdraw(job.proof);
      }

      job.txHash = tx.transaction_hash;
      job.status = "confirmed";
      job.updatedAt = Date.now();
    } catch (err: unknown) {
      job.status = "failed";
      job.error = err instanceof Error ? err.message : String(err);
      job.updatedAt = Date.now();
    }
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
    return this.poolContract.invoke("withdraw", [
      proof.proofData.map((v) => v.toString()),
      proof.merkleRoot.toString(),
      proof.nullifiers.map((v) => v.toString()),
      proof.outputCommitments[0]?.toString() ?? "0",
      "0", // recipient placeholder — real relayer would require it in the proof bundle
      {
        low: (exitValue & ((1n << 128n) - 1n)).toString(),
        high: (exitValue >> 128n).toString(),
      },
      "0", // assetId
    ]);
  }
}
