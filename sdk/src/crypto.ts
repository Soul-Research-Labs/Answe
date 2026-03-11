/**
 * Cryptographic primitives — mirrors the Cairo primitives crate.
 *
 * Uses starknet.js Poseidon implementation which matches Starknet's native builtins.
 */
import { hash, ec, encode } from "starknet";

import type { Felt252 } from "./types.js";

// ─── Field validation ────────────────────────────────────────────

/** The Starknet prime field modulus: p = 2^251 + 17 * 2^192 + 1. */
const FIELD_PRIME = (1n << 251n) + 17n * (1n << 192n) + 1n;

/**
 * Validate that a value is a valid felt252 (0 <= v < FIELD_PRIME).
 * Throws if the value is out of range.
 */
export function assertValidFelt252(value: Felt252, label?: string): void {
  if (typeof value !== "bigint") {
    throw new TypeError(
      `${label ?? "value"} must be a bigint, got ${typeof value}`,
    );
  }
  if (value < 0n || value >= FIELD_PRIME) {
    throw new RangeError(`${label ?? "value"} out of felt252 range: ${value}`);
  }
}

// ─── Poseidon hashing ────────────────────────────────────────────

/**
 * Poseidon hash of two felt252 values.
 * Matches Cairo's `poseidon_hash_2(a, b)`.
 */
export function poseidonHash2(a: Felt252, b: Felt252): Felt252 {
  assertValidFelt252(a, "poseidonHash2.a");
  assertValidFelt252(b, "poseidonHash2.b");
  return BigInt(hash.computePoseidonHash(toHex(a), toHex(b)));
}

/**
 * Poseidon hash of four felt252 values (chained).
 * Matches Cairo's `poseidon_hash_4(a, b, c, d)`.
 */
export function poseidonHash4(
  a: Felt252,
  b: Felt252,
  c: Felt252,
  d: Felt252,
): Felt252 {
  assertValidFelt252(a, "poseidonHash4.a");
  assertValidFelt252(b, "poseidonHash4.b");
  assertValidFelt252(c, "poseidonHash4.c");
  assertValidFelt252(d, "poseidonHash4.d");
  return BigInt(
    hash.computePoseidonHashOnElements([
      toHex(a),
      toHex(b),
      toHex(c),
      toHex(d),
    ]),
  );
}

// ─── Note commitment ─────────────────────────────────────────────

export interface NoteInput {
  owner: Felt252;
  value: Felt252;
  assetId: Felt252;
  blinding: Felt252;
}

/**
 * Compute commitment = Poseidon(owner, value, asset_id, blinding).
 * Matches Cairo's `compute_note_commitment`.
 */
export function computeNoteCommitment(note: NoteInput): Felt252 {
  assertValidFelt252(note.owner, "commitment.owner");
  assertValidFelt252(note.value, "commitment.value");
  assertValidFelt252(note.assetId, "commitment.assetId");
  assertValidFelt252(note.blinding, "commitment.blinding");
  return poseidonHash4(note.owner, note.value, note.assetId, note.blinding);
}

// ─── Nullifier ───────────────────────────────────────────────────

/**
 * Compute nullifier V2 = Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id)).
 * Matches Cairo's `compute_nullifier_v2`.
 */
export function computeNullifier(
  spendingKey: Felt252,
  commitment: Felt252,
  chainId: Felt252,
  appId: Felt252,
): Felt252 {
  const inner = poseidonHash2(spendingKey, commitment);
  const domain = poseidonHash2(chainId, appId);
  return poseidonHash2(inner, domain);
}

// ─── Pedersen hashing (for backward compat) ──────────────────────

/**
 * Pedersen hash of two felt252 values.
 */
export function pedersenHash(a: Felt252, b: Felt252): Felt252 {
  return BigInt(hash.computeHashOnElements([toHex(a), toHex(b)]));
}

// ─── Random blinding factor ──────────────────────────────────────

const FELT252_MAX = FIELD_PRIME - 1n;

/**
 * Generate a cryptographically random felt252 for use as a blinding factor.
 */
export function randomFelt252(): Felt252 {
  // Use starknet.js randomness
  const privKey = ec.starkCurve.utils.randomPrivateKey();
  const hexStr = encode.addHexPrefix(encode.buf2hex(privKey));
  const val = BigInt(hexStr);
  return val % FELT252_MAX;
}

// ─── Helpers ─────────────────────────────────────────────────────

function toHex(v: Felt252): string {
  return "0x" + v.toString(16);
}
