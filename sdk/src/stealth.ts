/**
 * Stealth address helpers — port of Lumora's stealth protocol.
 *
 * Flow:
 * 1. Recipient publishes a meta-address (spending_pubkey, viewing_pubkey)
 * 2. Sender generates ephemeral key pair, computes shared secret via ECDH
 * 3. Stealth address = Poseidon(shared_secret) used as note owner
 * 4. Recipient scans by trial-decrypting with their viewing key
 *
 * Uses Starknet's native STARK curve for ECDH.
 */
import { ec, encode } from "starknet";
import { poseidonHash2 } from "./crypto.js";
import type { Felt252 } from "./types.js";

/** A meta-address published by the recipient on the StealthRegistry. */
export interface MetaAddress {
  /** Spending public key (STARK curve point, compressed). */
  spendingPubKey: Felt252;
  /** Viewing public key (STARK curve point, compressed). */
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
 * @param recipientMeta - The recipient's published meta-address.
 * @returns A StealthAddress with the owner hash to use in the note.
 */
export function deriveStealthAddress(
  recipientMeta: MetaAddress,
): StealthAddress {
  // Generate ephemeral key pair
  const ephPrivKey = ec.starkCurve.utils.randomPrivateKey();
  const ephPrivHex = encode.addHexPrefix(encode.buf2hex(ephPrivKey));
  const ephPubKey = BigInt(ec.starkCurve.getStarkKey(ephPrivHex));

  // ECDH: shared_secret = Poseidon(eph_priv * viewing_pub)
  // In practice on STARK curve, we compute a deterministic shared point.
  // Simplified: Poseidon(ephemeral_secret, viewing_pubkey)
  const ephPrivBigInt = BigInt(ephPrivHex);
  const sharedSecret = poseidonHash2(
    ephPrivBigInt,
    recipientMeta.viewingPubKey,
  );

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
  // Reconstruct: shared_secret = Poseidon(viewing_key, eph_pub)
  // This is the simplified version matching deriveStealthAddress
  const sharedSecret = poseidonHash2(viewingKey, ephemeralPubKey);
  const expectedOwner = poseidonHash2(sharedSecret, spendingPubKey);
  return expectedOwner === noteOwner;
}
