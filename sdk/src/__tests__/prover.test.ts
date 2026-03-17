import { describe, it, expect, vi } from "vitest";
import {
  ClientMerkleTree,
  generateTransferProof,
  generateWithdrawProof,
  generateTransferProofAsync,
  generateWithdrawProofAsync,
} from "../prover.js";
import {
  poseidonHash2,
  computeNoteCommitment,
  randomFelt252,
} from "../crypto.js";
import { NoteManager } from "../notes.js";
import type { Felt252, ProofResult } from "../types.js";
import type { ProverBackend, WitnessPayload } from "../stone-prover.js";

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

// ─── Async Proof Generation (Backend-routed) ─────────────────────

describe("generateTransferProofAsync", () => {
  /** Mock backend that records received witness and returns transformed proof data. */
  function makeMockBackend(
    transform: (w: WitnessPayload) => Felt252[] = (w) => [
      ...w.publicInputs,
      99n,
    ],
  ): ProverBackend & { lastWitness: WitnessPayload | null } {
    const backend = {
      name: "mock-backend",
      lastWitness: null as WitnessPayload | null,
      async prove(witness: WitnessPayload): Promise<ProofResult> {
        backend.lastWitness = witness;
        return {
          success: true,
          proof: {
            proofType: witness.circuitType === "transfer" ? 1 : 2,
            merkleRoot: witness.publicInputs[0] ?? 0n,
            nullifiers: [
              witness.publicInputs[1] ?? 0n,
              witness.publicInputs[2] ?? 0n,
            ],
            outputCommitments: witness.publicInputs.slice(3, 5),
            fee: 0n,
            proofData: transform(witness),
          },
        };
      },
      async healthCheck() {
        return true;
      },
    };
    return backend;
  }

  it("routes transfer witness through backend", async () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 1000n, tree);
    const note1 = makeNote(nm, 500n, tree);
    const recipientOwner = poseidonHash2(0x9999n, 0n);
    const backend = makeMockBackend();

    const result = await generateTransferProofAsync(
      {
        spendingKey: SK,
        inputNotes: [note0, note1],
        recipientOwnerHash: recipientOwner,
        amount: 300n,
        assetId: 0n,
        chainId: CHAIN_ID,
        appId: APP_ID,
        tree,
      },
      backend,
    );

    expect(result.success).toBe(true);
    expect(result.proof).toBeDefined();
    // Backend received a witness
    expect(backend.lastWitness).not.toBeNull();
    expect(backend.lastWitness!.circuitType).toBe("transfer");
    // Public inputs: [root, nf0, nf1, oc0, oc1, fee]
    expect(backend.lastWitness!.publicInputs).toHaveLength(6);
    // Proof data comes from backend (has the 99n sentinel)
    expect(result.proof!.proofData).toContain(99n);
    // But public inputs are preserved from local computation
    expect(result.proof!.proofType).toBe(1);
    expect(result.proof!.nullifiers).toHaveLength(2);
    expect(result.proof!.outputCommitments).toHaveLength(2);
  });

  it("propagates backend failure", async () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 500n, tree);
    const note1 = makeNote(nm, 500n, tree);
    const failBackend: ProverBackend = {
      name: "fail-backend",
      async prove() {
        return { success: false, error: "remote prover down" };
      },
      async healthCheck() {
        return false;
      },
    };

    const result = await generateTransferProofAsync(
      {
        spendingKey: SK,
        inputNotes: [note0, note1],
        recipientOwnerHash: poseidonHash2(0x5555n, 0n),
        amount: 200n,
        assetId: 0n,
        chainId: CHAIN_ID,
        appId: APP_ID,
        tree,
      },
      failBackend,
    );

    expect(result.success).toBe(false);
    expect(result.error).toBe("remote prover down");
  });

  it("returns local error on invalid inputs (before reaching backend)", async () => {
    const tree = new ClientMerkleTree(); // empty tree
    const nm = new NoteManager();
    const backend = makeMockBackend();

    const result = await generateTransferProofAsync(
      {
        spendingKey: SK,
        inputNotes: [
          nm.createNote(OWNER, 100n, 0n),
          nm.createNote(OWNER, 100n, 0n),
        ],
        recipientOwnerHash: OWNER,
        amount: 50n,
        assetId: 0n,
        chainId: CHAIN_ID,
        appId: APP_ID,
        tree,
      },
      backend,
    );

    expect(result.success).toBe(false);
    // Backend should NOT have been called
    expect(backend.lastWitness).toBeNull();
  });
});

describe("generateWithdrawProofAsync", () => {
  function makeMockBackend(): ProverBackend & {
    lastWitness: WitnessPayload | null;
  } {
    const backend = {
      name: "mock-backend",
      lastWitness: null as WitnessPayload | null,
      async prove(witness: WitnessPayload): Promise<ProofResult> {
        backend.lastWitness = witness;
        return {
          success: true,
          proof: {
            proofType: 2,
            merkleRoot: witness.publicInputs[0] ?? 0n,
            nullifiers: [
              witness.publicInputs[1] ?? 0n,
              witness.publicInputs[2] ?? 0n,
            ],
            outputCommitments: [witness.publicInputs[3] ?? 0n],
            fee: 0n,
            proofData: [...witness.publicInputs, 77n],
          },
        };
      },
      async healthCheck() {
        return true;
      },
    };
    return backend;
  }

  it("routes withdraw witness through backend", async () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 1000n, tree);
    const note1 = makeNote(nm, 500n, tree);
    const backend = makeMockBackend();

    const result = await generateWithdrawProofAsync(
      {
        spendingKey: SK,
        inputNotes: [note0, note1],
        exitValue: 400n,
        assetId: 0n,
        chainId: CHAIN_ID,
        appId: APP_ID,
        tree,
      },
      backend,
    );

    expect(result.success).toBe(true);
    expect(result.proof).toBeDefined();
    expect(backend.lastWitness).not.toBeNull();
    expect(backend.lastWitness!.circuitType).toBe("withdraw");
    // Public inputs: [root, nf0, nf1, changeCm, exitValue, assetId, fee]
    expect(backend.lastWitness!.publicInputs).toHaveLength(7);
    // Proof data comes from backend
    expect(result.proof!.proofData).toContain(77n);
    // Keep local public inputs
    expect(result.proof!.proofType).toBe(2);
    expect(result.proof!.exitValue).toBe(400n);
  });

  it("preserves non-zero assetId in withdraw witness public inputs", async () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 900n, tree, 7n);
    const note1 = makeNote(nm, 600n, tree, 7n);
    const backend = makeMockBackend();

    const result = await generateWithdrawProofAsync(
      {
        spendingKey: SK,
        inputNotes: [note0, note1],
        exitValue: 500n,
        assetId: 7n,
        chainId: CHAIN_ID,
        appId: APP_ID,
        tree,
      },
      backend,
    );

    expect(result.success).toBe(true);
    expect(backend.lastWitness).not.toBeNull();
    // Public input layout: [root, nf0, nf1, changeCm, exitValue, assetId, fee]
    expect(backend.lastWitness!.publicInputs[5]).toBe(7n);
  });

  it("propagates backend failure on withdraw", async () => {
    const nm = new NoteManager();
    const tree = new ClientMerkleTree();
    const note0 = makeNote(nm, 500n, tree);
    const note1 = makeNote(nm, 500n, tree);
    const failBackend: ProverBackend = {
      name: "fail-backend",
      async prove() {
        return { success: false, error: "GPU OOM" };
      },
      async healthCheck() {
        return false;
      },
    };

    const result = await generateWithdrawProofAsync(
      {
        spendingKey: SK,
        inputNotes: [note0, note1],
        exitValue: 500n,
        assetId: 0n,
        chainId: CHAIN_ID,
        appId: APP_ID,
        tree,
      },
      failBackend,
    );

    expect(result.success).toBe(false);
    expect(result.error).toBe("GPU OOM");
  });
});
