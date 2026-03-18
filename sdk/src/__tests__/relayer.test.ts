import { describe, it, expect } from "vitest";
import {
  Relayer,
  InMemoryJobStorage,
  type RelayerConfig,
  type JobStorageAdapter,
} from "../relayer.js";
import type { ProofRequest } from "../types.js";

/**
 * Unit tests for the Relayer — validation, job storage adapter,
 * nonce management, retry behaviour, and recovery.
 * Network calls are expected to fail (no devnet), but we can verify
 * all non-network logic.
 */

const CONFIG: RelayerConfig = {
  rpcUrl: "http://127.0.0.1:5050/rpc",
  account: { address: "0x1234", privateKey: "0xABCD" },
  contracts: { pool: "0x5678" },
  minFee: 10n,
  maxPending: 5,
};

function validProof(overrides: Partial<ProofRequest> = {}): ProofRequest {
  return {
    proofType: 1,
    merkleRoot: 0xabcn,
    nullifiers: [0x111n, 0x222n],
    outputCommitments: [0x333n, 0x444n],
    fee: 100n,
    proofData: [0x1n, 0x2n, 0x3n],
    ...overrides,
  };
}

describe("Relayer validation", () => {
  it("rejects duplicate nullifiers", async () => {
    const relayer = new Relayer(CONFIG);
    const proof = validProof({ nullifiers: [0x111n, 0x111n] });
    await expect(relayer.submit(proof)).rejects.toThrow("Duplicate nullifiers");
  });

  it("rejects zero nullifiers", async () => {
    const relayer = new Relayer(CONFIG);
    const proof = validProof({ nullifiers: [0n, 0x222n] });
    await expect(relayer.submit(proof)).rejects.toThrow("Zero nullifier");
  });

  it("rejects fee below minimum", async () => {
    const relayer = new Relayer(CONFIG);
    const proof = validProof({ fee: 5n });
    await expect(relayer.submit(proof)).rejects.toThrow("Fee too low");
  });

  it("rejects empty proof data", async () => {
    const relayer = new Relayer(CONFIG);
    const proof = validProof({ proofData: [] });
    await expect(relayer.submit(proof)).rejects.toThrow("Empty proof data");
  });

  it("rejects invalid proof type", async () => {
    const relayer = new Relayer(CONFIG);
    const proof = validProof({ proofType: 3 as any });
    await expect(relayer.submit(proof)).rejects.toThrow("Invalid proof type");
  });

  it("accepts valid proof and creates a job", async () => {
    const relayer = new Relayer(CONFIG);
    const proof = validProof();
    // submit will create a job but the async process will fail (no network)
    const jobId = await relayer.submit(proof);
    expect(jobId).toMatch(/^relay_/);
    const job = await relayer.getJob(jobId);
    expect(job).toBeDefined();
    expect(job!.proof).toEqual(proof);
  });

  it("enforces max pending limit", async () => {
    // To test queue full, we need jobs to stay "pending" at validation time.
    // Since process() runs async and moves to "submitted" immediately,
    // we test by checking that the validation error message is correct
    // when we manually construct the scenario.
    const relayer = new Relayer({ ...CONFIG, maxPending: 0 });
    await expect(
      relayer.submit(validProof({ nullifiers: [0x5n, 0x6n] })),
    ).rejects.toThrow("queue full");
  });

  it("getJobs returns all jobs", async () => {
    const relayer = new Relayer(CONFIG);
    await relayer.submit(validProof({ nullifiers: [0x10n, 0x20n] }));
    await relayer.submit(validProof({ nullifiers: [0x30n, 0x40n] }));
    const all = await relayer.getJobs();
    expect(all.length).toBe(2);
  });

  it("getJob returns undefined for unknown id", async () => {
    const relayer = new Relayer(CONFIG);
    expect(await relayer.getJob("nonexistent")).toBeUndefined();
  });

  it("rejects withdraw proofs without recipient", async () => {
    const relayer = new Relayer(CONFIG);
    const proof = validProof({ proofType: 2, recipient: undefined });
    await expect(relayer.submit(proof)).rejects.toThrow("recipient");
  });
});

// ─── InMemoryJobStorage ────────────────────────────────────────

describe("InMemoryJobStorage", () => {
  it("saves and loads a job", async () => {
    const storage = new InMemoryJobStorage();
    const job = {
      id: "relay_0",
      proof: validProof(),
      status: "pending" as const,
      retries: 0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    await storage.save(job);
    const loaded = await storage.load("relay_0");
    expect(loaded).toBeDefined();
    expect(loaded!.id).toBe("relay_0");
  });

  it("returns undefined for missing job", async () => {
    const storage = new InMemoryJobStorage();
    expect(await storage.load("nonexistent")).toBeUndefined();
  });

  it("deletes a job", async () => {
    const storage = new InMemoryJobStorage();
    const job = {
      id: "relay_1",
      proof: validProof(),
      status: "pending" as const,
      retries: 0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    await storage.save(job);
    await storage.delete("relay_1");
    expect(await storage.load("relay_1")).toBeUndefined();
  });

  it("loadAll returns all jobs", async () => {
    const storage = new InMemoryJobStorage();
    const now = Date.now();
    await storage.save({
      id: "relay_0",
      proof: validProof(),
      status: "pending",
      retries: 0,
      createdAt: now,
      updatedAt: now,
    });
    await storage.save({
      id: "relay_1",
      proof: validProof({ nullifiers: [0x50n, 0x60n] }),
      status: "confirmed",
      retries: 0,
      createdAt: now,
      updatedAt: now,
    });
    const all = await storage.loadAll();
    expect(all.length).toBe(2);
  });

  it("loadAll filters by status", async () => {
    const storage = new InMemoryJobStorage();
    const now = Date.now();
    await storage.save({
      id: "relay_0",
      proof: validProof(),
      status: "pending",
      retries: 0,
      createdAt: now,
      updatedAt: now,
    });
    await storage.save({
      id: "relay_1",
      proof: validProof({ nullifiers: [0x50n, 0x60n] }),
      status: "confirmed",
      retries: 0,
      createdAt: now,
      updatedAt: now,
    });
    const pending = await storage.loadAll("pending");
    expect(pending.length).toBe(1);
    expect(pending[0].id).toBe("relay_0");
  });

  it("nextId increments", async () => {
    const storage = new InMemoryJobStorage();
    expect(await storage.nextId()).toBe(0);
    expect(await storage.nextId()).toBe(1);
    expect(await storage.nextId()).toBe(2);
  });

  it("save returns a copy (no aliasing)", async () => {
    const storage = new InMemoryJobStorage();
    const job = {
      id: "relay_0",
      proof: validProof(),
      status: "pending" as const,
      retries: 0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    await storage.save(job);
    const loaded = await storage.load("relay_0");
    loaded!.status = "failed";
    const original = await storage.load("relay_0");
    expect(original!.status).toBe("pending");
  });
});

// ─── Custom Storage Adapter ─────────────────────────────────────

describe("Relayer with custom storage adapter", () => {
  it("uses provided storage adapter", async () => {
    const storage = new InMemoryJobStorage();
    const relayer = new Relayer({ ...CONFIG, storage });
    const jobId = await relayer.submit(validProof());
    const stored = await storage.load(jobId);
    expect(stored).toBeDefined();
    expect(stored!.id).toBe(jobId);
  });
});

// ─── Retry / Failure Behaviour ──────────────────────────────────

describe("Relayer retry behaviour", () => {
  it("jobs eventually fail after max retries (no network)", async () => {
    const storage = new InMemoryJobStorage();
    const relayer = new Relayer({
      ...CONFIG,
      storage,
      maxRetries: 1,
      confirmationTimeoutMs: 100,
    });
    const jobId = await relayer.submit(validProof());

    // Wait for the async processing queue to settle.
    // With jitter (up to 2s per attempt) + 1s backoff for maxRetries=1,
    // the total worst-case is ~5s; use 7s to avoid flakiness.
    await new Promise((r) => setTimeout(r, 7000));

    const job = await storage.load(jobId);
    expect(job).toBeDefined();
    expect(job!.status).toBe("failed");
    expect(job!.error).toBeDefined();
    expect(job!.retries).toBeGreaterThan(0);
  }, 10_000);

  it("job moves from pending → submitted → failed lifecycle", async () => {
    const storage = new InMemoryJobStorage();
    const relayer = new Relayer({
      ...CONFIG,
      storage,
      maxRetries: 0,
      confirmationTimeoutMs: 100,
    });
    const jobId = await relayer.submit(validProof());

    // Let the processing queue run
    await new Promise((r) => setTimeout(r, 2000));

    const job = await storage.load(jobId);
    expect(job).toBeDefined();
    expect(job!.status).toBe("failed");
  });
});

// ─── Recovery ───────────────────────────────────────────────────

describe("Relayer recovery", () => {
  it("recover returns count of jobs to retry", async () => {
    const storage = new InMemoryJobStorage();
    const now = Date.now();
    // Seed storage with pending and submitted jobs (simulating a restart)
    await storage.save({
      id: "relay_0",
      proof: validProof(),
      status: "pending",
      retries: 0,
      createdAt: now,
      updatedAt: now,
    });
    await storage.save({
      id: "relay_1",
      proof: validProof({ nullifiers: [0x50n, 0x60n] }),
      status: "submitted",
      retries: 1,
      createdAt: now,
      updatedAt: now,
      txHash: "0xABC",
    });
    // Confirmed jobs should NOT be retried
    await storage.save({
      id: "relay_2",
      proof: validProof({ nullifiers: [0x70n, 0x80n] }),
      status: "confirmed",
      retries: 0,
      createdAt: now,
      updatedAt: now,
    });

    const relayer = new Relayer({ ...CONFIG, storage, maxRetries: 0 });
    const count = await relayer.recover();
    expect(count).toBe(2); // only pending + submitted
  });
});

// ─── sweepStale ──────────────────────────────────────────────────
describe("sweepStale", () => {
  it("marks stale submitted jobs as failed", async () => {
    const storage = new InMemoryJobStorage();
    const now = Date.now();

    // Stale submitted job (updated 10 minutes ago)
    await storage.save({
      id: "relay_0",
      proof: validProof(),
      status: "submitted",
      retries: 1,
      createdAt: now - 600_000,
      updatedAt: now - 600_000,
      txHash: "0xabc",
    });
    // Fresh submitted job (just now)
    await storage.save({
      id: "relay_1",
      proof: validProof({ nullifiers: [0x30n, 0x40n] }),
      status: "submitted",
      retries: 0,
      createdAt: now,
      updatedAt: now,
    });
    // A pending job (should be untouched)
    await storage.save({
      id: "relay_2",
      proof: validProof({ nullifiers: [0x50n, 0x60n] }),
      status: "pending",
      retries: 0,
      createdAt: now - 600_000,
      updatedAt: now - 600_000,
    });

    const relayer = new Relayer({ ...CONFIG, storage });
    const swept = await relayer.sweepStale(300_000); // 5 min threshold
    expect(swept).toBe(1);

    const staleJob = await storage.load("relay_0");
    expect(staleJob?.status).toBe("failed");
    expect(staleJob?.error).toContain("Stale");
    expect(staleJob?.error).toContain("0xabc");

    // Fresh submitted job untouched
    const freshJob = await storage.load("relay_1");
    expect(freshJob?.status).toBe("submitted");

    // Pending job untouched
    const pendingJob = await storage.load("relay_2");
    expect(pendingJob?.status).toBe("pending");
  });

  it("returns 0 when no stale jobs exist", async () => {
    const storage = new InMemoryJobStorage();
    const relayer = new Relayer({ ...CONFIG, storage });
    const swept = await relayer.sweepStale();
    expect(swept).toBe(0);
  });
});

// ─── getStats ────────────────────────────────────────────────────
describe("getStats", () => {
  it("returns correct counts per status", async () => {
    const storage = new InMemoryJobStorage();
    const now = Date.now();
    const mkJob = (id: string, status: string) => ({
      id,
      proof: validProof({
        nullifiers: [BigInt(parseInt(id.slice(-1)) * 2 + 1)],
      }),
      status: status as any,
      retries: 0,
      createdAt: now,
      updatedAt: now,
    });

    await storage.save(mkJob("relay_0", "pending"));
    await storage.save(mkJob("relay_1", "submitted"));
    await storage.save(mkJob("relay_2", "submitted"));
    await storage.save(mkJob("relay_3", "confirmed"));
    await storage.save(mkJob("relay_4", "confirmed"));
    await storage.save(mkJob("relay_5", "confirmed"));
    await storage.save(mkJob("relay_6", "failed"));

    const relayer = new Relayer({ ...CONFIG, storage });
    const stats = await relayer.getStats();
    expect(stats).toEqual({
      pending: 1,
      submitted: 2,
      confirmed: 3,
      failed: 1,
      total: 7,
    });
  });
});
