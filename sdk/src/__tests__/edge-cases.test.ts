/**
 * Edge case tests for SDK correctness.
 */
import { describe, it, expect } from "vitest";
import { ClientMerkleTree, generateTransferProof, generateWithdrawProof } from "../prover.js";
import { NoteManager } from "../notes.js";
import { poseidonHash2, randomFelt252, computeNoteCommitment } from "../crypto.js";
import { padEnvelope, ENVELOPE_SIZE, buildBatch, wrapProof } from "../metadata.js";
import { KeyManager } from "../keys.js";
import type { ProofRequest } from "../types.js";

const SK = 0x1234n;
const OWNER = poseidonHash2(SK, 0n);
const CHAIN_ID = BigInt("0x534e5f5345504f4c4941");
const APP_ID = 0xabcn;

function makeNote(nm: NoteManager, value: bigint, tree: ClientMerkleTree) {
  const note = nm.createNote(OWNER, value, 0n);
  const idx = tree.insert(note.commitment);
  nm.confirmNote(note.id, idx);
  return note;
}

// ─── Merkle Tree Edge Cases ──────────────────────────────────────

describe("ClientMerkleTree edge cases", () => {
  it("single leaf has a valid root", () => {
    const tree = new ClientMerkleTree();
    tree.insert(1n);
    const root = tree.getRoot();
    expect(root).not.toBe(0n);
  });

  it("proof for leaf 0 works", () => {
    const tree = new ClientMerkleTree();
    tree.insert(42n);
    const proof = tree.getProof(0);
    expect(proof.length).toBe(32);
  });

  it("out-of-range leaf index throws", () => {
    const tree = new ClientMerkleTree();
    tree.insert(1n);
    expect(() => tree.getProof(-1)).toThrow();
    expect(() => tree.getProof(1)).toThrow();
  });

  it("root differs after adding a leaf", () => {
    const tree = new ClientMerkleTree();
    tree.insert(1n);
    const root1 = tree.getRoot();
    tree.insert(2n);
    const root2 = tree.getRoot();
    expect(root1).not.toBe(root2);
  });

  it("loadLeaves replaces existing leaves", () => {
    const tree = new ClientMerkleTree();
    tree.insert(1n);
    tree.insert(2n);
    expect(tree.leafCount).toBe(2);
    tree.loadLeaves([10n, 20n, 30n]);
    expect(tree.leafCount).toBe(3);
  });
});

// ─── Transfer Proof Edge Cases ───────────────────────────────────

describe("Transfer proof edge cases", () => {
  it("exact amount transfer (zero change)", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 500n, tree);
    const note1 = makeNote(nm, 500n, tree);

    const result = generateTransferProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      recipientOwnerHash: poseidonHash2(0x5555n, 0n),
      amount: 1000n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      tree,
    });

    expect(result.success).toBe(true);
    expect(result.proof!.outputCommitments.length).toBe(2);
  });

  it("minimum value transfer (1 unit)", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 1n, tree);
    const note1 = makeNote(nm, 1n, tree);

    const result = generateTransferProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      recipientOwnerHash: OWNER,
      amount: 1n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      tree,
    });

    expect(result.success).toBe(true);
  });

  it("same recipient and sender (self-transfer)", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 100n, tree);
    const note1 = makeNote(nm, 100n, tree);

    const result = generateTransferProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      recipientOwnerHash: OWNER,
      amount: 50n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      tree,
    });

    expect(result.success).toBe(true);
  });
});

// ─── Withdraw Proof Edge Cases ───────────────────────────────────

describe("Withdraw proof edge cases", () => {
  it("full withdrawal (zero change)", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 1000n, tree);
    const note1 = makeNote(nm, 0n, tree);

    const result = generateWithdrawProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      exitValue: 1000n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      tree,
    });

    expect(result.success).toBe(true);
    expect(result.proof!.exitValue).toBe(1000n);
  });

  it("withdraw with fee leaving zero change", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 100n, tree);
    const note1 = makeNote(nm, 10n, tree);

    const result = generateWithdrawProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      exitValue: 100n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      fee: 10n,
      tree,
    });

    expect(result.success).toBe(true);
  });
});

// ─── Metadata Edge Cases ─────────────────────────────────────────

describe("Metadata edge cases", () => {
  it("pad empty payload", () => {
    const padded = padEnvelope([]);
    expect(padded.length).toBe(ENVELOPE_SIZE);
    expect(padded.every((v) => v === 0n)).toBe(true);
  });

  it("pad exactly ENVELOPE_SIZE payload", () => {
    const data = new Array(ENVELOPE_SIZE).fill(1n);
    const padded = padEnvelope(data);
    expect(padded.length).toBe(ENVELOPE_SIZE);
  });

  it("pad oversized payload throws", () => {
    const data = new Array(ENVELOPE_SIZE + 1).fill(1n);
    expect(() => padEnvelope(data)).toThrow("Payload too large");
  });

  it("batch with maximum proofs allowed", () => {
    const proofs: ProofRequest[] = Array.from({ length: 8 }, (_, i) => ({
      proofType: 1 as const,
      merkleRoot: BigInt(i),
      nullifiers: [BigInt(i * 2 + 1), BigInt(i * 2 + 2)] as [bigint, bigint],
      outputCommitments: [BigInt(i * 100)],
      fee: 0n,
      proofData: [1n],
    }));
    const batch = buildBatch(proofs, 8);
    expect(batch.envelopes.length).toBe(8);
  });

  it("batch overflow throws", () => {
    const proofs: ProofRequest[] = Array.from({ length: 9 }, (_, i) => ({
      proofType: 1 as const,
      merkleRoot: BigInt(i),
      nullifiers: [BigInt(i * 2 + 1), BigInt(i * 2 + 2)] as [bigint, bigint],
      outputCommitments: [BigInt(i * 100)],
      fee: 0n,
      proofData: [1n],
    }));
    expect(() => buildBatch(proofs, 8)).toThrow("Too many proofs");
  });
});

// ─── Key Manager Edge Cases ──────────────────────────────────────

describe("KeyManager edge cases", () => {
  it("generate produces distinct keys each time", () => {
    const k1 = KeyManager.generate();
    const k2 = KeyManager.generate();
    expect(k1.spendingKey).not.toBe(k2.spendingKey);
    expect(k1.viewingKey).not.toBe(k2.viewingKey);
    expect(k1.ownerHash).not.toBe(k2.ownerHash);
  });

  it("fromSpendingKey reproduces same derived keys", () => {
    const original = KeyManager.generate();
    const restored = KeyManager.fromSpendingKey(original.spendingKey);
    expect(restored.viewingKey).toBe(original.viewingKey);
    expect(restored.ownerHash).toBe(original.ownerHash);
  });

  it("different spending keys produce different owner hashes", () => {
    const owners = new Set<bigint>();
    for (let i = 0; i < 50; i++) {
      const km = KeyManager.generate();
      owners.add(km.ownerHash);
    }
    expect(owners.size).toBe(50);
  });
});

// ─── Randomized Commitment Uniqueness ────────────────────────────

describe("Randomized commitment uniqueness", () => {
  it("100 random notes all have unique commitments", () => {
    const nm = new NoteManager();
    const commitments = new Set<bigint>();
    for (let i = 0; i < 100; i++) {
      const note = nm.createNote(OWNER, 100n, 0n);
      expect(commitments.has(note.commitment)).toBe(false);
      commitments.add(note.commitment);
    }
    expect(commitments.size).toBe(100);
  });

  it("100 random felt252 values are all unique", () => {
    const values = new Set<bigint>();
    for (let i = 0; i < 100; i++) {
      values.add(randomFelt252());
    }
    expect(values.size).toBe(100);
  });
});
