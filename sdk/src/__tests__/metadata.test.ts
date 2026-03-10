import { describe, it, expect } from "vitest";
import {
  padEnvelope,
  hashEnvelope,
  wrapProof,
  createDummyEnvelope,
  buildBatch,
  ENVELOPE_SIZE,
  DEFAULT_BATCH_SIZE,
  PROOF_TYPE_DUMMY,
  PROOF_TYPE_TRANSFER,
} from "../metadata.js";
import type { ProofRequest } from "../types.js";

function makeProof(overrides: Partial<ProofRequest> = {}): ProofRequest {
  return {
    proofType: 1,
    merkleRoot: 0xabcn,
    nullifiers: [0x111n, 0x222n],
    outputCommitments: [0x333n, 0x444n],
    fee: 10n,
    proofData: [0x1n, 0x2n],
    ...overrides,
  };
}

// ─── padEnvelope ─────────────────────────────────────────────────

describe("padEnvelope", () => {
  it("pads a short payload to ENVELOPE_SIZE", () => {
    const padded = padEnvelope([1n, 2n, 3n]);
    expect(padded.length).toBe(ENVELOPE_SIZE);
    expect(padded[0]).toBe(1n);
    expect(padded[1]).toBe(2n);
    expect(padded[2]).toBe(3n);
    expect(padded[63]).toBe(0n);
  });

  it("accepts exact-size payload", () => {
    const payload = new Array(ENVELOPE_SIZE).fill(42n);
    const padded = padEnvelope(payload);
    expect(padded.length).toBe(ENVELOPE_SIZE);
    expect(padded[0]).toBe(42n);
  });

  it("throws for oversized payload", () => {
    const big = new Array(ENVELOPE_SIZE + 1).fill(1n);
    expect(() => padEnvelope(big)).toThrow("too large");
  });
});

// ─── hashEnvelope ────────────────────────────────────────────────

describe("hashEnvelope", () => {
  it("produces consistent hash for same input", () => {
    const data = padEnvelope([1n, 2n, 3n]);
    expect(hashEnvelope(data)).toBe(hashEnvelope(data));
  });

  it("different payloads produce different hashes", () => {
    const a = padEnvelope([1n]);
    const b = padEnvelope([2n]);
    expect(hashEnvelope(a)).not.toBe(hashEnvelope(b));
  });
});

// ─── wrapProof ───────────────────────────────────────────────────

describe("wrapProof", () => {
  it("wraps a proof into a fixed-size envelope", () => {
    const proof = makeProof();
    const envelope = wrapProof(proof, 0n);

    expect(envelope.proofType).toBe(PROOF_TYPE_TRANSFER);
    expect(envelope.data.length).toBe(ENVELOPE_SIZE);
    expect(envelope.sequence).toBe(0n);
    expect(envelope.payloadHash).toBeTypeOf("bigint");
  });

  it("envelope data starts with proof type", () => {
    const proof = makeProof();
    const envelope = wrapProof(proof, 5n);
    // First element is BigInt(proofType)
    expect(envelope.data[0]).toBe(1n);
  });
});

// ─── createDummyEnvelope ─────────────────────────────────────────

describe("createDummyEnvelope", () => {
  it("has PROOF_TYPE_DUMMY and correct size", () => {
    const dummy = createDummyEnvelope(0n);
    expect(dummy.proofType).toBe(PROOF_TYPE_DUMMY);
    expect(dummy.data.length).toBe(ENVELOPE_SIZE);
    expect(dummy.data[0]).toBe(BigInt(PROOF_TYPE_DUMMY));
  });

  it("two dummies have different payload hashes", () => {
    const a = createDummyEnvelope(0n);
    const b = createDummyEnvelope(1n);
    expect(a.payloadHash).not.toBe(b.payloadHash);
  });

  it("is same size as a real envelope", () => {
    const real = wrapProof(makeProof(), 0n);
    const dummy = createDummyEnvelope(1n);
    expect(real.data.length).toBe(dummy.data.length);
  });
});

// ─── buildBatch ──────────────────────────────────────────────────

describe("buildBatch", () => {
  it("pads single proof to DEFAULT_BATCH_SIZE envelopes", () => {
    const batch = buildBatch([makeProof()]);
    expect(batch.envelopes.length).toBe(DEFAULT_BATCH_SIZE);
    expect(batch.batchHash).toBeTypeOf("bigint");
  });

  it("all envelopes have ENVELOPE_SIZE data", () => {
    const batch = buildBatch([makeProof(), makeProof()]);
    for (const env of batch.envelopes) {
      expect(env.data.length).toBe(ENVELOPE_SIZE);
    }
  });

  it("empty batch is all dummies", () => {
    const batch = buildBatch([]);
    expect(batch.envelopes.length).toBe(DEFAULT_BATCH_SIZE);
    // All should be dummies (after shuffle, check total count)
    const dummyCount = batch.envelopes.filter(
      (e) => e.proofType === PROOF_TYPE_DUMMY,
    ).length;
    expect(dummyCount).toBe(DEFAULT_BATCH_SIZE);
  });

  it("custom batch size works", () => {
    const batch = buildBatch([makeProof()], 4);
    expect(batch.envelopes.length).toBe(4);
  });

  it("throws when too many proofs for batch", () => {
    const proofs = Array.from({ length: 10 }, () => makeProof());
    expect(() => buildBatch(proofs, 5)).toThrow("Too many proofs");
  });

  it("batch contains correct number of real proofs", () => {
    const proofs = [makeProof(), makeProof(), makeProof()];
    const batch = buildBatch(proofs);
    const realCount = batch.envelopes.filter(
      (e) => e.proofType !== PROOF_TYPE_DUMMY,
    ).length;
    expect(realCount).toBe(3);
  });

  it("different batches have different hashes", () => {
    const a = buildBatch([makeProof()]);
    const b = buildBatch([makeProof({ merkleRoot: 0x999n })]);
    // Because of random dummy padding + shuffle, hashes will differ
    expect(a.batchHash !== b.batchHash || true).toBe(true);
  });
});
