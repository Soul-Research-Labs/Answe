import { describe, it, expect } from "vitest";
import { Relayer, type RelayerConfig } from "../relayer.js";
import type { ProofRequest } from "../types.js";

/**
 * Unit tests for the Relayer validation logic.
 * Network calls are expected to fail (no devnet), but we can verify
 * job creation, validation, and state management.
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
    const job = relayer.getJob(jobId);
    expect(job).toBeDefined();
    expect(job!.proof).toBe(proof);
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
    const all = relayer.getJobs();
    expect(all.length).toBe(2);
  });

  it("getJob returns undefined for unknown id", () => {
    const relayer = new Relayer(CONFIG);
    expect(relayer.getJob("nonexistent")).toBeUndefined();
  });
});
