/**
 * Metadata resistance module — ensures all proof submissions are
 * indistinguishable by payload size and timing.
 *
 * Mirrors the Cairo `metadata.cairo` envelope format:
 * - Fixed ENVELOPE_SIZE (64 felt252 elements)
 * - Dummy envelope padding for batch uniformity
 * - Relay jitter for timing resistance
 *
 * Reference: Plan step 19 — port Lumora's metadata leakage reduction.
 */
import { poseidonHash2, randomFelt252 } from "./crypto.js";
import type { Felt252, ProofRequest } from "./types.js";

/** Every proof envelope is exactly this many felt252 elements. */
export const ENVELOPE_SIZE = 64;

export const PROOF_TYPE_TRANSFER = 1;
export const PROOF_TYPE_WITHDRAW = 2;
export const PROOF_TYPE_DUMMY = 3;

// ─── Proof Envelope ──────────────────────────────────────────────

export interface ProofEnvelope {
  proofType: number;
  payloadHash: Felt252;
  sequence: bigint;
  /** Padded payload — always exactly ENVELOPE_SIZE elements. */
  data: Felt252[];
}

/**
 * Pad an arbitrary-length payload to ENVELOPE_SIZE.
 * Real payload is placed at the front; remaining slots filled with zeros.
 */
export function padEnvelope(payload: Felt252[]): Felt252[] {
  if (payload.length > ENVELOPE_SIZE) {
    throw new Error(`Payload too large: ${payload.length} > ${ENVELOPE_SIZE}`);
  }
  const padded = new Array<Felt252>(ENVELOPE_SIZE).fill(0n);
  for (let i = 0; i < payload.length; i++) {
    padded[i] = payload[i];
  }
  return padded;
}

/**
 * Compute the Poseidon hash of an envelope payload (chained pairwise).
 */
export function hashEnvelope(data: Felt252[]): Felt252 {
  let h = data[0] ?? 0n;
  for (let i = 1; i < data.length; i++) {
    h = poseidonHash2(h, data[i]);
  }
  return h;
}

/**
 * Wrap a ProofRequest into a fixed-size ProofEnvelope.
 */
export function wrapProof(
  proof: ProofRequest,
  sequence: bigint,
): ProofEnvelope {
  const raw: Felt252[] = [
    BigInt(proof.proofType),
    proof.merkleRoot,
    proof.nullifiers[0],
    proof.nullifiers[1],
    ...proof.outputCommitments,
    proof.exitValue ?? 0n,
    proof.fee,
    ...proof.proofData,
  ];

  const data = padEnvelope(raw);
  return {
    proofType: proof.proofType,
    payloadHash: hashEnvelope(data),
    sequence,
    data,
  };
}

/**
 * Create a dummy envelope that is indistinguishable in size from real ones.
 */
export function createDummyEnvelope(sequence: bigint): ProofEnvelope {
  const data = new Array<Felt252>(ENVELOPE_SIZE);
  data[0] = BigInt(PROOF_TYPE_DUMMY);
  for (let i = 1; i < ENVELOPE_SIZE; i++) {
    data[i] = randomFelt252();
  }
  return {
    proofType: PROOF_TYPE_DUMMY,
    payloadHash: hashEnvelope(data),
    sequence,
    data,
  };
}

// ─── Batch Accumulator ───────────────────────────────────────────

/** Default batch size — all batches are padded to this many envelopes. */
export const DEFAULT_BATCH_SIZE = 8;

export interface Batch {
  envelopes: ProofEnvelope[];
  batchHash: Felt252;
  createdAt: number;
}

/**
 * Accumulate proof envelopes into a fixed-size batch.
 *
 * If fewer than `batchSize` real proofs are provided, dummy envelopes
 * are appended so every batch looks identical in size. The batch is then
 * shuffled so the position of real vs. dummy envelopes is not revealed.
 */
export function buildBatch(
  proofs: ProofRequest[],
  batchSize: number = DEFAULT_BATCH_SIZE,
): Batch {
  if (proofs.length > batchSize) {
    throw new Error(
      `Too many proofs for batch: ${proofs.length} > ${batchSize}`,
    );
  }

  let seq = 0n;
  const envelopes: ProofEnvelope[] = [];

  // Wrap real proofs
  for (const p of proofs) {
    envelopes.push(wrapProof(p, seq++));
  }

  // Pad with dummies
  while (envelopes.length < batchSize) {
    envelopes.push(createDummyEnvelope(seq++));
  }

  // Rejection sampling shuffle — avoids modular bias
  for (let i = envelopes.length - 1; i > 0; i--) {
    const bound = BigInt(i + 1);
    // Rejection sampling: re-draw if value falls in biased zone
    const maxUnbiased = (2n ** 251n) - ((2n ** 251n) % bound);
    let r: bigint;
    do {
      r = randomFelt252();
    } while (r >= maxUnbiased);
    const j = Number(r % bound);
    [envelopes[i], envelopes[j]] = [envelopes[j], envelopes[i]];
  }

  // Compute batch commitment
  let batchHash = envelopes[0].payloadHash;
  for (let i = 1; i < envelopes.length; i++) {
    batchHash = poseidonHash2(batchHash, envelopes[i].payloadHash);
  }

  return { envelopes, batchHash, createdAt: Date.now() };
}

// ─── Relay Jitter ────────────────────────────────────────────────

/**
 * Add random delay (jitter) before relaying a transaction.
 * This prevents timing analysis from linking a user's request
 * to an on-chain transaction submission.
 *
 * @param minMs - Minimum delay in milliseconds (default 100).
 * @param maxMs - Maximum delay in milliseconds (default 2000).
 */
export function relayJitter(
  minMs: number = 100,
  maxMs: number = 2000,
): Promise<void> {
  const range = BigInt(maxMs - minMs);
  // Rejection sampling to avoid modular bias
  const maxUnbiased = (2n ** 251n) - ((2n ** 251n) % range);
  let r: bigint;
  do {
    r = randomFelt252();
  } while (r >= maxUnbiased);
  const delay = minMs + Number(r % range);
  return new Promise((resolve) => setTimeout(resolve, delay));
}
