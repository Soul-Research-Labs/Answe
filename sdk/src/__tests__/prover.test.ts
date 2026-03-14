import { describe, it, expect } from "vitest";
import {
  ClientMerkleTree,
  generateTransferProof,
  generateWithdrawProof,
} from "../prover.js";
import {
  poseidonHash2,
  computeNoteCommitment,
  randomFelt252,
} from "../crypto.js";
import { NoteManager } from "../notes.js";
import type { Felt252 } from "../types.js";

const SK = 0x1234n;
const OWNER = poseidonHash2(SK, 0n);
const CHAIN_ID = BigInt("0x534e5f5345504f4c4941"); // 'SN_SEPOLIA'
const APP_ID = 0xabcn;

function makeNote(nm: NoteManager, value: bigint, tree: ClientMerkleTree) {
  const note = nm.createNote(OWNER, value, 0n);
  const idx = tree.insert(note.commitment);
  nm.confirmNote(note.id, idx);
  return note;
}

// ─── ClientMerkleTree ────────────────────────────────────────────

describe("ClientMerkleTree", () => {
  it("empty tree has a deterministic root", () => {
    const tree = new ClientMerkleTree();
    const root = tree.getRoot();
    expect(root).toBeTypeOf("bigint");
    expect(tree.leafCount).toBe(0);
  });

  it("inserting a leaf changes the root", () => {
    const tree = new ClientMerkleTree();
    const emptyRoot = tree.getRoot();
    tree.insert(0x42n);
    expect(tree.getRoot()).not.toBe(emptyRoot);
    expect(tree.leafCount).toBe(1);
  });

  it("generates a proof of correct length", () => {
    const tree = new ClientMerkleTree();
    tree.insert(0x1n);
    tree.insert(0x2n);
    const proof = tree.getProof(0);
    expect(proof.length).toBe(32);
  });

  it("proof verifies against the root", () => {
    const tree = new ClientMerkleTree();
    const leaf = 0xcafen;
    tree.insert(leaf);
    const proof = tree.getProof(0);
    const root = tree.getRoot();

    // Manually recompute root from leaf + proof
    let current = leaf;
    let idx = 0;
    for (let i = 0; i < 32; i++) {
      const sibling = proof[i];
      current =
        idx % 2 === 0
          ? poseidonHash2(current, sibling)
          : poseidonHash2(sibling, current);
      idx = Math.floor(idx / 2);
    }
    expect(current).toBe(root);
  });

  it("throws for out-of-range leaf index", () => {
    const tree = new ClientMerkleTree();
    tree.insert(0x1n);
    expect(() => tree.getProof(5)).toThrow("out of range");
  });

  it("loadLeaves initialises from an array", () => {
    const tree = new ClientMerkleTree();
    tree.loadLeaves([0x1n, 0x2n, 0x3n]);
    expect(tree.leafCount).toBe(3);
    const proof = tree.getProof(2);
    expect(proof.length).toBe(32);
  });
});

// ─── Transfer Proof Generation ───────────────────────────────────

describe("generateTransferProof", () => {
  it("generates a valid transfer proof", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();

    const note0 = makeNote(nm, 1000n, tree);
    const note1 = makeNote(nm, 500n, tree);
    const recipientOwner = poseidonHash2(0x9999n, 0n);

    const result = generateTransferProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      recipientOwnerHash: recipientOwner,
      amount: 800n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      tree,
    });

    expect(result.success).toBe(true);
    expect(result.proof).toBeDefined();
    expect(result.proof!.proofType).toBe(1);
    expect(result.proof!.nullifiers.length).toBe(2);
    expect(result.proof!.outputCommitments.length).toBe(2);
    expect(result.proof!.merkleRoot).toBe(tree.getRoot());
    expect(result.proof!.fee).toBe(0n);
    // proofData should contain witness elements
    expect(result.proof!.proofData.length).toBeGreaterThan(0);
  });

  it("includes fee in the proof", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();

    const note0 = makeNote(nm, 1000n, tree);
    const note1 = makeNote(nm, 500n, tree);
    const recipientOwner = poseidonHash2(0x5555n, 0n);

    const result = generateTransferProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      recipientOwnerHash: recipientOwner,
      amount: 400n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      fee: 10n,
      tree,
    });

    expect(result.success).toBe(true);
    expect(result.proof!.fee).toBe(10n);
  });

  it("fails when input notes have no leaf index", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();

    // Create notes but don't confirm them (no leaf index)
    const note0 = nm.createNote(OWNER, 100n, 0n);
    const note1 = nm.createNote(OWNER, 200n, 0n);

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

    expect(result.success).toBe(false);
    expect(result.error).toMatch(/no leaf index|empty/i);
  });

  it("fails when amount exceeds input value", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();

    const note0 = makeNote(nm, 100n, tree);
    const note1 = makeNote(nm, 50n, tree);

    const result = generateTransferProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      recipientOwnerHash: OWNER,
      amount: 200n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      tree,
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain("Insufficient");
  });

  it("produces distinct nullifiers for distinct notes", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();

    const note0 = makeNote(nm, 500n, tree);
    const note1 = makeNote(nm, 500n, tree);

    const result = generateTransferProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      recipientOwnerHash: OWNER,
      amount: 100n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      tree,
    });

    expect(result.success).toBe(true);
    expect(result.proof!.nullifiers[0]).not.toBe(result.proof!.nullifiers[1]);
  });
});

// ─── Withdraw Proof Generation ───────────────────────────────────

describe("generateWithdrawProof", () => {
  it("generates a valid withdrawal proof", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();

    const note0 = makeNote(nm, 2000n, tree);
    const note1 = makeNote(nm, 1000n, tree);

    const result = generateWithdrawProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      exitValue: 1500n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      tree,
    });

    expect(result.success).toBe(true);
    expect(result.proof).toBeDefined();
    expect(result.proof!.proofType).toBe(2);
    expect(result.proof!.nullifiers.length).toBe(2);
    expect(result.proof!.outputCommitments.length).toBe(1); // change only
    expect(result.proof!.exitValue).toBe(1500n);
    expect(result.proof!.merkleRoot).toBe(tree.getRoot());
  });

  it("includes fee in withdrawal", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();

    const note0 = makeNote(nm, 1000n, tree);
    const note1 = makeNote(nm, 500n, tree);

    const result = generateWithdrawProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      exitValue: 800n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      fee: 25n,
      tree,
    });

    expect(result.success).toBe(true);
    expect(result.proof!.fee).toBe(25n);
  });

  it("fails when exit + fee exceeds input", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();

    const note0 = makeNote(nm, 100n, tree);
    const note1 = makeNote(nm, 50n, tree);

    const result = generateWithdrawProof({
      spendingKey: SK,
      inputNotes: [note0, note1],
      exitValue: 140n,
      assetId: 0n,
      chainId: CHAIN_ID,
      appId: APP_ID,
      fee: 20n,
      tree,
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain("Insufficient");
  });

  it("full withdraw (zero change) succeeds", () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();

    const note0 = makeNote(nm, 500n, tree);
    const note1 = makeNote(nm, 500n, tree);

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
});
