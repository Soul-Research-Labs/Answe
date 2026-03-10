/**
 * Cryptographic primitives — mirrors the Cairo primitives crate.
 *
 * Uses starknet.js Poseidon implementation which matches Starknet's native builtins.
 */
import { hash, ec, encode } from "starknet";

import type { Felt252 } from "./types.js";

// ─── Poseidon hashing ────────────────────────────────────────────

/**
 * Poseidon hash of two felt252 values.
 * Matches Cairo's `poseidon_hash_2(a, b)`.
 */
export function poseidonHash2(a: Felt252, b: Felt252): Felt252 {
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

const FELT252_MAX = (1n << 251n) + 17n * (1n << 192n);

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
