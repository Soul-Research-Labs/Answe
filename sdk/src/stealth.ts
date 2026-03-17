/**
 * Stealth address helpers — port of Lumora's stealth protocol.
 *
 * Flow:
 * 1. Recipient publishes a meta-address (spending_pubkey, viewing_pubkey)
 * 2. Sender generates ephemeral key pair, computes shared secret via ECDH
 * 3. Stealth address = Poseidon(shared_secret) used as note owner
 * 4. Recipient scans by trial-decrypting with their viewing key
 *
 * Uses Starknet's native STARK curve for real ECDH key agreement.
 */
import { ec, encode } from "starknet";
import { poseidonHash2 } from "./crypto.js";
import type { Felt252 } from "./types.js";

// ─── STARK Curve ECDH ───────────────────────────────────────────
//
// The Stark curve is y² = x³ + α·x + β over F_p.
// For ECDH, given a private scalar `s` and a peer's public key x-coordinate,
// we lift x to a curve point and compute s * Point. The x-coordinate of the
// resulting point is the raw shared secret.
//
// The choice of y-sign during liftX does NOT affect the result's x-coordinate
// because negating a point only flips y: s * (-P) = -(s * P) → same x.

const _sc = ec.starkCurve as any;
const CURVE_ORDER: bigint = _sc.CURVE.n as bigint;

function assertValidScalar(value: bigint, label: string): void {
  if (value <= 0n) {
    throw new Error(`${label} must be non-zero`);
  }
  if (value >= CURVE_ORDER) {
    throw new Error(`${label} out of Stark curve scalar range`);
  }
}

function assertValidPublicKeyX(value: bigint, label: string): void {
  if (value <= 0n) {
    throw new Error(`${label} must be non-zero`);
  }
}

/**
 * Recover a STARK curve point from its x-coordinate.
 * Uses y² = x³ + α·x + β and the field's sqrt function.
 */
function liftX(x: bigint): any {
  assertValidPublicKeyX(x, "public key");
  const Fp = _sc.CURVE.Fp;
  const { a, b } = _sc.CURVE;
  const { ProjectivePoint } = _sc;
  const x3 = Fp.mul(Fp.mul(x, x), x);
  const ax = Fp.mul(a, x);
  const y2 = Fp.add(Fp.add(x3, ax), b);
  const y = Fp.sqrt(y2);
  if (y === undefined) {
    throw new Error("Invalid public key: x-coordinate not on Stark curve");
  }
  return ProjectivePoint.fromAffine({ x, y });
}

/**
 * Compute the ECDH shared secret between a private scalar and a public key
 * x-coordinate. Returns Poseidon(shared_x, 0) for domain separation.
 *
 * This is symmetric: ecdhShared(a, PubB) === ecdhShared(b, PubA)
 * because a * (b·G) and b * (a·G) have the same x-coordinate.
 */
function ecdhShared(privateKey: bigint, publicKeyX: bigint): Felt252 {
  assertValidScalar(privateKey, "private scalar");
  const pubPoint = liftX(publicKeyX);
  const sharedPoint = pubPoint.multiply(privateKey);
  const sharedX: bigint = sharedPoint.toAffine().x;
  return poseidonHash2(sharedX, 0n);
}

/** A meta-address published by the recipient on the StealthRegistry. */
export interface MetaAddress {
  /** Spending public key (STARK curve point, compressed x-coordinate). */
  spendingPubKey: Felt252;
  /** Viewing public key (STARK curve point, compressed x-coordinate). */
  viewingPubKey: Felt252;
}

/** A stealth address derived for a one-time payment. */
export interface StealthAddress {
  /** The stealth owner hash to use in the note. */
  ownerHash: Felt252;
  /** The ephemeral public key (to publish for the recipient). */
  ephemeralPubKey: Felt252;
  /** The shared secret (for the sender's records only). */
  sharedSecret: Felt252;
}

/**
 * Derive a stealth address for a recipient.
 *
 * Performs real ECDH: sharedSecret = Poseidon((ephPriv * viewingPubPoint).x, 0).
 * The recipient can recover the same secret using their viewing private key
 * and the published ephemeral public key.
 *
 * @param recipientMeta - The recipient's published meta-address.
 * @returns A StealthAddress with the owner hash to use in the note.
 */
export function deriveStealthAddress(
  recipientMeta: MetaAddress,
): StealthAddress {
  assertValidPublicKeyX(recipientMeta.spendingPubKey, "spending public key");
  assertValidPublicKeyX(recipientMeta.viewingPubKey, "viewing public key");

  // Generate ephemeral key pair
  const ephPrivKey = ec.starkCurve.utils.randomPrivateKey();
  const ephPrivHex = encode.addHexPrefix(encode.buf2hex(ephPrivKey));
  const ephPubKey = BigInt(ec.starkCurve.getStarkKey(ephPrivHex));
  const ephPrivBigInt = BigInt(ephPrivHex);

  // ECDH: shared_secret = Poseidon((ephPriv * viewingPubPoint).x, 0)
  const sharedSecret = ecdhShared(ephPrivBigInt, recipientMeta.viewingPubKey);

  // Stealth owner = Poseidon(shared_secret, spending_pubkey)
  const ownerHash = poseidonHash2(sharedSecret, recipientMeta.spendingPubKey);

  return {
    ownerHash,
    ephemeralPubKey: ephPubKey,
    sharedSecret,
  };
}

/**
 * Try to detect if a note belongs to us (recipient scanning).
 *
 * Performs real ECDH: sharedSecret = Poseidon((viewingKey * ephPubPoint).x, 0).
 * This matches the sender's computation because ECDH is symmetric:
 *   ephPriv * viewingPubPoint == viewingKey * ephPubPoint (same x-coordinate).
 *
 * @param ephemeralPubKey - The ephemeral pub key from the sender.
 * @param viewingKey - Our viewing private key.
 * @param spendingPubKey - Our spending public key.
 * @param noteOwner - The owner field in the note.
 * @returns true if this note is for us.
 */
export function tryScanNote(
  ephemeralPubKey: Felt252,
  viewingKey: Felt252,
  spendingPubKey: Felt252,
  noteOwner: Felt252,
): boolean {
  try {
    // ECDH: shared_secret = Poseidon((viewingKey * ephPubPoint).x, 0)
    const sharedSecret = ecdhShared(viewingKey, ephemeralPubKey);
    const expectedOwner = poseidonHash2(sharedSecret, spendingPubKey);
    return expectedOwner === noteOwner;
  } catch {
    // Fail closed for malformed keys/events during scanning.
    return false;
  }
}
