/**
 * Proof generation module — assembles STARK proof witnesses for
 * the TransferCircuit and WithdrawCircuit.
 *
 * In the MVP this constructs the witness and proof data structures
 * client-side. A production deployment would send the witness to a
 * remote stone-prover or s-two instance and receive a STARK proof back.
 */
import {
  poseidonHash2,
  computeNoteCommitment,
  computeNullifier,
  randomFelt252,
} from "./crypto.js";
import type { PrivacyNote } from "./notes.js";
import type { Felt252, ProofRequest, ProofResult } from "./types.js";
import type { ProverBackend, WitnessPayload } from "./stone-prover.js";

const TREE_DEPTH = 32;

// ─── Merkle tree helpers (client-side mirror) ────────────────────

/**
 * Compute zero hashes for a depth-32 Poseidon Merkle tree.
 * z[0] = 0, z[i+1] = Poseidon(z[i], z[i]).
 */
function computeZeroHashes(): Felt252[] {
  const z: Felt252[] = new Array(TREE_DEPTH + 1);
  z[0] = 0n;
  for (let i = 0; i < TREE_DEPTH; i++) {
    z[i + 1] = poseidonHash2(z[i], z[i]);
  }
  return z;
}

const ZERO_HASHES = computeZeroHashes();

/**
 * Lightweight in-memory Merkle tree that mirrors the on-chain tree.
 * Used to compute Merkle proofs for proof generation.
 */
export class ClientMerkleTree {
  private leaves: Felt252[] = [];
  private layers: Felt252[][] = [];

  /**
   * Number of leaves currently in the tree.
   */
  get leafCount(): number {
    return this.leaves.length;
  }

  /**
   * Insert a leaf commitment (mirrors on-chain append).
   */
  insert(commitment: Felt252): number {
    const index = this.leaves.length;
    this.leaves.push(commitment);
    this.rebuild();
    return index;
  }

  /**
   * Bulk-load leaves (e.g., from historical events).
   */
  loadLeaves(commitments: Felt252[]): void {
    this.leaves = [...commitments];
    this.rebuild();
  }

  /**
   * Get the current Merkle root.
   */
  getRoot(): Felt252 {
    if (this.layers.length === 0) return ZERO_HASHES[TREE_DEPTH];
    return this.layers[this.layers.length - 1][0];
  }

  /**
   * Generate a Merkle proof (array of TREE_DEPTH siblings) for a leaf.
   */
  getProof(leafIndex: number): Felt252[] {
    if (leafIndex < 0 || leafIndex >= this.leaves.length) {
      throw new Error(`Leaf index ${leafIndex} out of range`);
    }

    const proof: Felt252[] = [];
    let idx = leafIndex;

    for (let depth = 0; depth < TREE_DEPTH; depth++) {
      const layer = this.layers[depth];
      const siblingIdx = idx % 2 === 0 ? idx + 1 : idx - 1;

      if (layer && siblingIdx < layer.length) {
        proof.push(layer[siblingIdx]);
      } else {
        proof.push(ZERO_HASHES[depth]);
      }

      idx = Math.floor(idx / 2);
    }

    return proof;
  }

  /**
   * Rebuild all internal layers from leaves.
   */
  private rebuild(): void {
    if (this.leaves.length === 0) {
      this.layers = [];
      return;
    }

    this.layers = [this.leaves.slice()];

    for (let depth = 0; depth < TREE_DEPTH; depth++) {
      const prev = this.layers[depth];
      const next: Felt252[] = [];
      for (let i = 0; i < prev.length; i += 2) {
        const left = prev[i];
        const right = i + 1 < prev.length ? prev[i + 1] : ZERO_HASHES[depth];
        next.push(poseidonHash2(left, right));
      }
      this.layers.push(next);
    }
  }
}

// ─── Transfer proof generation ───────────────────────────────────

export interface TransferProofInput {
  /** Spending key of the note owner. */
  spendingKey: Felt252;
  /** The two input notes being consumed. */
  inputNotes: [PrivacyNote, PrivacyNote];
  /** Recipient's owner hash for the primary output. */
  recipientOwnerHash: Felt252;
  /** Amount to send to the recipient. */
  amount: bigint;
  /** Asset ID. */
  assetId: Felt252;
  /** Chain ID for domain separation. */
  chainId: Felt252;
  /** App ID for domain separation. */
  appId: Felt252;
  /** Fee for the relayer (default 0). */
  fee?: bigint;
  /** Client-side Merkle tree with all leaves loaded. */
  tree: ClientMerkleTree;
}

/**
 * Generate a transfer proof request.
 *
 * Computes nullifiers, output commitments, Merkle proofs, and
 * assembles the full witness. In production, the witness would
 * be sent to a STARK prover; here we return a ProofResult with
 * the assembled proof data.
 */
export function generateTransferProof(input: TransferProofInput): ProofResult {
  try {
    const {
      spendingKey,
      inputNotes,
      recipientOwnerHash,
      amount,
      assetId,
      chainId,
      appId,
      tree,
    } = input;
    const fee = input.fee ?? 0n;

    // Validate tree has been synced with on-chain state
    if (tree.leafCount === 0) {
      return {
        success: false,
        error:
          "Merkle tree is empty — call syncTree() with on-chain commitments before generating proofs",
      };
    }

    // Validate leaf indices exist
    for (let i = 0; i < 2; i++) {
      if (inputNotes[i].leafIndex === undefined) {
        return { success: false, error: `Input note ${i} has no leaf index` };
      }
    }

    // Compute commitments
    const cm0 = inputNotes[0].commitment;
    const cm1 = inputNotes[1].commitment;

    // Compute nullifiers
    const nf0 = computeNullifier(spendingKey, cm0, chainId, appId);
    const nf1 = computeNullifier(spendingKey, cm1, chainId, appId);

    // Compute Merkle proofs
    const path0 = tree.getProof(inputNotes[0].leafIndex!);
    const path1 = tree.getProof(inputNotes[1].leafIndex!);
    const root = tree.getRoot();

    // Compute output notes
    const totalIn = inputNotes[0].value + inputNotes[1].value;
    const change = totalIn - amount - fee;

    if (change < 0n) {
      return { success: false, error: "Insufficient input value" };
    }

    const outputBlinding0 = randomFelt252();
    const outputBlinding1 = randomFelt252();

    const outputCm0 = computeNoteCommitment({
      owner: recipientOwnerHash,
      value: amount,
      assetId,
      blinding: outputBlinding0,
    });

    const senderOwnerHash = poseidonHash2(spendingKey, 0n);
    const outputCm1 = computeNoteCommitment({
      owner: senderOwnerHash,
      value: change,
      assetId,
      blinding: outputBlinding1,
    });

    // Assemble proof data as flat array:
    // [spending_key, in0_fields(4), in1_fields(4), path0(32), idx0, path1(32), idx1,
    //  out0_fields(4), out1_fields(4)]
    const proofData: Felt252[] = [
      spendingKey,
      // Input note 0
      inputNotes[0].owner,
      BigInt(inputNotes[0].value),
      inputNotes[0].assetId,
      inputNotes[0].blinding,
      // Input note 1
      inputNotes[1].owner,
      BigInt(inputNotes[1].value),
      inputNotes[1].assetId,
      inputNotes[1].blinding,
      // Merkle path 0
      ...path0,
      BigInt(inputNotes[0].leafIndex!),
      // Merkle path 1
      ...path1,
      BigInt(inputNotes[1].leafIndex!),
      // Output note 0
      recipientOwnerHash,
      amount,
      assetId,
      outputBlinding0,
      // Output note 1
      senderOwnerHash,
      change,
      assetId,
      outputBlinding1,
    ];

    const proof: ProofRequest = {
      proofType: 1,
      merkleRoot: root,
      nullifiers: [nf0, nf1],
      outputCommitments: [outputCm0, outputCm1],
      fee,
      proofData,
    };

    return { success: true, proof };
  } catch (err: unknown) {
    return {
      success: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

// ─── Withdraw proof generation ───────────────────────────────────

export interface WithdrawProofInput {
  /** Spending key of the note owner. */
  spendingKey: Felt252;
  /** The two input notes being consumed. */
  inputNotes: [PrivacyNote, PrivacyNote];
  /** Amount to withdraw publicly. */
  exitValue: bigint;
  /** Asset ID. */
  assetId: Felt252;
  /** Chain ID for domain separation. */
  chainId: Felt252;
  /** App ID for domain separation. */
  appId: Felt252;
  /** Fee for the relayer (default 0). */
  fee?: bigint;
  /** Client-side Merkle tree with all leaves loaded. */
  tree: ClientMerkleTree;
}

/**
 * Generate a withdrawal proof request.
 *
 * Computes nullifiers, change commitment, Merkle proofs, and
 * assembles the full witness for the WithdrawCircuit.
 */
export function generateWithdrawProof(input: WithdrawProofInput): ProofResult {
  try {
    const {
      spendingKey,
      inputNotes,
      exitValue,
      assetId,
      chainId,
      appId,
      tree,
    } = input;
    const fee = input.fee ?? 0n;

    // Validate tree has been synced with on-chain state
    if (tree.leafCount === 0) {
      return {
        success: false,
        error:
          "Merkle tree is empty — call syncTree() with on-chain commitments before generating proofs",
      };
    }

    for (let i = 0; i < 2; i++) {
      if (inputNotes[i].leafIndex === undefined) {
        return { success: false, error: `Input note ${i} has no leaf index` };
      }
    }

    const cm0 = inputNotes[0].commitment;
    const cm1 = inputNotes[1].commitment;

    const nf0 = computeNullifier(spendingKey, cm0, chainId, appId);
    const nf1 = computeNullifier(spendingKey, cm1, chainId, appId);

    const path0 = tree.getProof(inputNotes[0].leafIndex!);
    const path1 = tree.getProof(inputNotes[1].leafIndex!);
    const root = tree.getRoot();

    const totalIn = inputNotes[0].value + inputNotes[1].value;
    const changeValue = totalIn - exitValue - fee;

    if (changeValue < 0n) {
      return {
        success: false,
        error: "Insufficient input value for withdrawal",
      };
    }

    const senderOwnerHash = poseidonHash2(spendingKey, 0n);
    const changeBlinding = randomFelt252();
    const changeCm = computeNoteCommitment({
      owner: senderOwnerHash,
      value: changeValue,
      assetId,
      blinding: changeBlinding,
    });

    // Assemble proof data:
    // [spending_key, in0_fields(4), in1_fields(4), path0(32), idx0, path1(32), idx1,
    //  change_fields(4)]
    const proofData: Felt252[] = [
      spendingKey,
      inputNotes[0].owner,
      BigInt(inputNotes[0].value),
      inputNotes[0].assetId,
      inputNotes[0].blinding,
      inputNotes[1].owner,
      BigInt(inputNotes[1].value),
      inputNotes[1].assetId,
      inputNotes[1].blinding,
      ...path0,
      BigInt(inputNotes[0].leafIndex!),
      ...path1,
      BigInt(inputNotes[1].leafIndex!),
      senderOwnerHash,
      changeValue,
      assetId,
      changeBlinding,
    ];

    const proof: ProofRequest = {
      proofType: 2,
      merkleRoot: root,
      nullifiers: [nf0, nf1],
      outputCommitments: [changeCm],
      exitValue,
      fee,
      proofData,
    };

    return { success: true, proof };
  } catch (err: unknown) {
    return {
      success: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

// ─── Backend-routed proof generation (async) ─────────────────────

/**
 * Split a transfer witness into public and private inputs suitable
 * for a remote prover backend.
 */
function splitTransferWitness(
  root: Felt252,
  nf0: Felt252,
  nf1: Felt252,
  oc0: Felt252,
  oc1: Felt252,
  fee: bigint,
  privateData: Felt252[],
): WitnessPayload {
  return {
    circuitType: "transfer",
    publicInputs: [root, nf0, nf1, oc0, oc1, fee],
    privateInputs: privateData,
  };
}

/**
 * Split a withdraw witness into public and private inputs suitable
 * for a remote prover backend.
 */
function splitWithdrawWitness(
  root: Felt252,
  nf0: Felt252,
  nf1: Felt252,
  changeCm: Felt252,
  exitValue: bigint,
  assetId: Felt252,
  fee: bigint,
  privateData: Felt252[],
): WitnessPayload {
  return {
    circuitType: "withdraw",
    publicInputs: [root, nf0, nf1, changeCm, exitValue, assetId, fee],
    privateInputs: privateData,
  };
}

/**
 * Generate a transfer proof routed through a ProverBackend.
 *
 * Assembles the witness locally, sends it to the backend for STARK
 * proof generation, and returns the result with real proof data.
 */
export async function generateTransferProofAsync(
  input: TransferProofInput,
  backend: ProverBackend,
): Promise<ProofResult> {
  const localResult = generateTransferProof(input);
  if (!localResult.success || !localResult.proof) {
    return localResult;
  }

  const { proof } = localResult;
  const witness = splitTransferWitness(
    proof.merkleRoot,
    proof.nullifiers[0],
    proof.nullifiers[1],
    proof.outputCommitments[0],
    proof.outputCommitments[1],
    proof.fee,
    proof.proofData,
  );

  const backendResult = await backend.prove(witness);
  if (!backendResult.success || !backendResult.proof) {
    return backendResult;
  }

  return {
    success: true,
    proof: {
      ...proof,
      proofData: backendResult.proof.proofData,
    },
  };
}

/**
 * Generate a withdrawal proof routed through a ProverBackend.
 *
 * Assembles the witness locally, sends it to the backend for STARK
 * proof generation, and returns the result with real proof data.
 */
export async function generateWithdrawProofAsync(
  input: WithdrawProofInput,
  backend: ProverBackend,
): Promise<ProofResult> {
  const localResult = generateWithdrawProof(input);
  if (!localResult.success || !localResult.proof) {
    return localResult;
  }

  const { proof } = localResult;
  const witness = splitWithdrawWitness(
    proof.merkleRoot,
    proof.nullifiers[0],
    proof.nullifiers[1],
    proof.outputCommitments[0],
    proof.exitValue!,
    0n,
    proof.fee,
    proof.proofData,
  );

  const backendResult = await backend.prove(witness);
  if (!backendResult.success || !backendResult.proof) {
    return backendResult;
  }

  return {
    success: true,
    proof: {
      ...proof,
      proofData: backendResult.proof.proofData,
    },
  };
}
