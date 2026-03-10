/**
 * Key management for StarkPrivacy.
 *
 * Key hierarchy (matches Lumora's design):
 * - Master seed (random 32 bytes)
 *   ├── Spending key (sk) — authorizes note spending via nullifier derivation
 *   ├── Viewing key (vk) — derives from sk, enables balance scanning
 *   └── Scanning key   — enables trial decryption of incoming notes
 *
 * The owner field stored in notes = Poseidon(sk, 0).
 */
import { ec, encode } from "starknet";
import { poseidonHash2 } from "./crypto.js";
import type { Felt252 } from "./types.js";

export type SpendingKey = Felt252;
export type ViewingKey = Felt252;

export interface PrivacyKeyPair {
  /** The spending key (private — authorizes spending). */
  spendingKey: SpendingKey;
  /** The viewing key (semi-private — enables balance scanning). */
  viewingKey: ViewingKey;
  /** The owner hash = Poseidon(sk, 0), stored in notes. */
  ownerHash: Felt252;
}

/**
 * Key management for privacy operations.
 */
export class KeyManager {
  private readonly sk: SpendingKey;
  private readonly vk: ViewingKey;
  readonly ownerHash: Felt252;

  constructor(spendingKey: SpendingKey) {
    this.sk = spendingKey;
    // Viewing key = Poseidon(sk, 1) — deterministic derivation from spending key
    this.vk = poseidonHash2(spendingKey, 1n);
    // Owner hash = Poseidon(sk, 0) — stored in note commitments
    this.ownerHash = poseidonHash2(spendingKey, 0n);
  }

  /**
   * Generate a new random key pair.
   */
  static generate(): KeyManager {
    const privKey = ec.starkCurve.utils.randomPrivateKey();
    const hexStr = encode.addHexPrefix(encode.buf2hex(privKey));
    const sk = BigInt(hexStr);
    return new KeyManager(sk);
  }

  /**
   * Restore from an existing spending key.
   */
  static fromSpendingKey(sk: SpendingKey): KeyManager {
    return new KeyManager(sk);
  }

  /**
   * Export the full key pair.
   */
  exportKeys(): PrivacyKeyPair {
    return {
      spendingKey: this.sk,
      viewingKey: this.vk,
      ownerHash: this.ownerHash,
    };
  }

  get spendingKey(): SpendingKey {
    return this.sk;
  }

  get viewingKey(): ViewingKey {
    return this.vk;
  }
}
