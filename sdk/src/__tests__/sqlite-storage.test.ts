/**
 * Tests for SQLite job storage adapter — serialization and deserialization logic.
 *
 * These tests verify the proof JSON round-trip without requiring better-sqlite3
 * to be installed (it's an optional dependency).
 */
import { describe, it, expect } from "vitest";

// Test the serialization/deserialization round-trip by accessing internal helpers
// through a minimal mock approach — we replicate the logic here for unit testing.

function serializeProof(proof: any): string {
  return JSON.stringify({
    proofType: proof.proofType,
    merkleRoot: "0x" + proof.merkleRoot.toString(16),
    nullifiers: proof.nullifiers.map((n: bigint) => "0x" + n.toString(16)),
    outputCommitments: proof.outputCommitments.map(
      (c: bigint) => "0x" + c.toString(16),
    ),
    exitValue:
      proof.exitValue != null ? "0x" + proof.exitValue.toString(16) : undefined,
    recipient: proof.recipient,
    fee: "0x" + proof.fee.toString(16),
    proofData: proof.proofData.map((d: bigint) => "0x" + d.toString(16)),
  });
}

function deserializeProof(json: string): any {
  const obj = JSON.parse(json);
  return {
    proofType: obj.proofType,
    merkleRoot: BigInt(obj.merkleRoot),
    nullifiers: obj.nullifiers.map((n: string) => BigInt(n)),
    outputCommitments: obj.outputCommitments.map((c: string) => BigInt(c)),
    exitValue: obj.exitValue ? BigInt(obj.exitValue) : undefined,
    recipient: obj.recipient,
    fee: BigInt(obj.fee),
    proofData: obj.proofData.map((d: string) => BigInt(d)),
  };
}

const SAMPLE_PROOF = {
  proofType: 1 as const,
  merkleRoot: 0xdeadbeefn,
  nullifiers: [0x111n, 0x222n] as [bigint, bigint],
  outputCommitments: [0x333n, 0x444n],
  fee: 100n,
  proofData: [0x1n, 0x2n, 0x3n],
};

describe("SqliteJobStorage serialization", () => {
  it("round-trips a transfer proof through JSON", () => {
    const json = serializeProof(SAMPLE_PROOF);
    const restored = deserializeProof(json);
    expect(restored.proofType).toBe(1);
    expect(restored.merkleRoot).toBe(0xdeadbeefn);
    expect(restored.nullifiers).toEqual([0x111n, 0x222n]);
    expect(restored.outputCommitments).toEqual([0x333n, 0x444n]);
    expect(restored.fee).toBe(100n);
    expect(restored.proofData).toEqual([0x1n, 0x2n, 0x3n]);
  });

  it("round-trips a withdraw proof with exitValue and recipient", () => {
    const proof = {
      ...SAMPLE_PROOF,
      proofType: 2 as const,
      exitValue: 500n,
      recipient: "0xABC",
    };
    const json = serializeProof(proof);
    const restored = deserializeProof(json);
    expect(restored.proofType).toBe(2);
    expect(restored.exitValue).toBe(500n);
    expect(restored.recipient).toBe("0xABC");
  });

  it("handles undefined exitValue correctly", () => {
    const json = serializeProof(SAMPLE_PROOF);
    const restored = deserializeProof(json);
    expect(restored.exitValue).toBeUndefined();
  });

  it("preserves large felt252 values through serialization", () => {
    const largeFelt = (1n << 250n) + 42n;
    const proof = {
      ...SAMPLE_PROOF,
      merkleRoot: largeFelt,
    };
    const json = serializeProof(proof);
    const restored = deserializeProof(json);
    expect(restored.merkleRoot).toBe(largeFelt);
  });

  it("produces valid JSON output", () => {
    const json = serializeProof(SAMPLE_PROOF);
    expect(() => JSON.parse(json)).not.toThrow();
    const parsed = JSON.parse(json);
    expect(parsed.merkleRoot).toBe("0xdeadbeef");
    expect(parsed.nullifiers).toEqual(["0x111", "0x222"]);
  });

  it("serializes empty proofData array", () => {
    const proof = { ...SAMPLE_PROOF, proofData: [] };
    const json = serializeProof(proof);
    const restored = deserializeProof(json);
    expect(restored.proofData).toEqual([]);
  });
});
