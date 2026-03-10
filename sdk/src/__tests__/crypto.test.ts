import { describe, it, expect } from "vitest";
import {
  poseidonHash2,
  poseidonHash4,
  computeNoteCommitment,
  computeNullifier,
  randomFelt252,
  pedersenHash,
} from "../crypto.js";

describe("poseidonHash2", () => {
  it("produces deterministic output", () => {
    const a = 123n;
    const b = 456n;
    const h1 = poseidonHash2(a, b);
    const h2 = poseidonHash2(a, b);
    expect(h1).toBe(h2);
  });

  it("different inputs produce different hashes", () => {
    const h1 = poseidonHash2(1n, 2n);
    const h2 = poseidonHash2(2n, 1n);
    expect(h1).not.toBe(h2);
  });

  it("returns a bigint", () => {
    const h = poseidonHash2(0n, 0n);
    expect(typeof h).toBe("bigint");
    expect(h).toBeGreaterThan(0n);
  });
});

describe("poseidonHash4", () => {
  it("produces deterministic output", () => {
    const h1 = poseidonHash4(1n, 2n, 3n, 4n);
    const h2 = poseidonHash4(1n, 2n, 3n, 4n);
    expect(h1).toBe(h2);
  });

  it("is different from individual hash2 combinations", () => {
    const h4 = poseidonHash4(1n, 2n, 3n, 4n);
    const h2 = poseidonHash2(poseidonHash2(1n, 2n), poseidonHash2(3n, 4n));
    // poseidonHash4 uses computePoseidonHashOnElements, different from chained hash2
    expect(h4).not.toBe(h2);
  });
});

describe("computeNoteCommitment", () => {
  it("creates commitment from note fields", () => {
    const commitment = computeNoteCommitment({
      owner: 100n,
      value: 1000n,
      assetId: 0n,
      blinding: 999n,
    });
    expect(typeof commitment).toBe("bigint");
    expect(commitment).toBeGreaterThan(0n);
  });

  it("different blindings produce different commitments", () => {
    const base = { owner: 100n, value: 1000n, assetId: 0n };
    const c1 = computeNoteCommitment({ ...base, blinding: 1n });
    const c2 = computeNoteCommitment({ ...base, blinding: 2n });
    expect(c1).not.toBe(c2);
  });

  it("commitment is deterministic", () => {
    const params = { owner: 42n, value: 7n, assetId: 0n, blinding: 99n };
    const c1 = computeNoteCommitment(params);
    const c2 = computeNoteCommitment(params);
    expect(c1).toBe(c2);
  });
});

describe("computeNullifier", () => {
  it("produces deterministic nullifier", () => {
    const sk = 12345n;
    const commitment = 67890n;
    const chainId = 1n;
    const appId = 2n;
    const n1 = computeNullifier(sk, commitment, chainId, appId);
    const n2 = computeNullifier(sk, commitment, chainId, appId);
    expect(n1).toBe(n2);
  });

  it("different spending keys produce different nullifiers", () => {
    const cm = 100n;
    const n1 = computeNullifier(1n, cm, 1n, 1n);
    const n2 = computeNullifier(2n, cm, 1n, 1n);
    expect(n1).not.toBe(n2);
  });

  it("different chain/app IDs produce different nullifiers", () => {
    const n1 = computeNullifier(1n, 100n, 1n, 1n);
    const n2 = computeNullifier(1n, 100n, 2n, 1n);
    expect(n1).not.toBe(n2);
  });
});

describe("randomFelt252", () => {
  it("produces random values", () => {
    const r1 = randomFelt252();
    const r2 = randomFelt252();
    expect(r1).not.toBe(r2);
  });

  it("value is within felt252 range", () => {
    const FELT252_MAX = (1n << 251n) + 17n * (1n << 192n);
    for (let i = 0; i < 10; i++) {
      const r = randomFelt252();
      expect(r).toBeGreaterThanOrEqual(0n);
      expect(r).toBeLessThan(FELT252_MAX);
    }
  });
});

describe("pedersenHash", () => {
  it("produces deterministic output", () => {
    const h1 = pedersenHash(1n, 2n);
    const h2 = pedersenHash(1n, 2n);
    expect(h1).toBe(h2);
  });

  it("is different from poseidon hash", () => {
    const ped = pedersenHash(1n, 2n);
    const pos = poseidonHash2(1n, 2n);
    expect(ped).not.toBe(pos);
  });
});
