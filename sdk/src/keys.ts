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

/**
 * Securely zero-fill a Uint8Array in place.
 * Uses crypto.getRandomValues first (as a barrier against compiler
 * optimisation removing the write) then overwrites with zeros.
 */
export function zeroize(buf: Uint8Array): void {
  try {
    globalThis.crypto.getRandomValues(buf);
  } catch {
    // Fallback: environments without WebCrypto (rare)
  }
  buf.fill(0);
}

/** Secret key that authorizes note spending. Derived from a seed via Poseidon. */
export type SpendingKey = Felt252;
/** Key used for scanning stealth payments without spending authority. */
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
  private sk: SpendingKey | null;
  private vk: ViewingKey | null;
  private _ownerHash: Felt252;
  /** Raw seed bytes — kept so we can zeroize them on destroy(). */
  private seedBytes: Uint8Array | null;
  private destroyed = false;

  constructor(spendingKey: SpendingKey, seedBytes?: Uint8Array) {
    this.sk = spendingKey;
    this.seedBytes = seedBytes ?? null;
    // Viewing key = Poseidon(sk, 1) — deterministic derivation from spending key
    this.vk = poseidonHash2(spendingKey, 1n);
    // Owner hash = Poseidon(sk, 0) — stored in note commitments
    this._ownerHash = poseidonHash2(spendingKey, 0n);
  }

  private assertAlive(): void {
    if (this.destroyed) {
      throw new Error(
        "KeyManager has been destroyed — key material is no longer available.",
      );
    }
  }

  /**
   * Generate a new random key pair.
   */
  static generate(): KeyManager {
    const privKey = ec.starkCurve.utils.randomPrivateKey();
    const seedCopy = new Uint8Array(privKey);
    const hexStr = encode.addHexPrefix(encode.buf2hex(privKey));
    const sk = BigInt(hexStr);
    // Zeroize the original buffer returned by the library
    zeroize(privKey);
    return new KeyManager(sk, seedCopy);
  }

  /**
   * Restore from an existing spending key.
   */
  static fromSpendingKey(sk: SpendingKey): KeyManager {
    return new KeyManager(sk);
  }

  /**
   * Export the full key pair.
   *
   * **SECURITY WARNING**: The spending key grants full control over all
   * shielded funds. Never share it, log it, or transmit it over insecure
   * channels. Store it with the same care as a private key.
   *
   * @param iUnderstandTheRisk - Must be true to acknowledge the risk of
   *   exporting the raw spending key. Throws if not provided.
   */
  exportKeys(iUnderstandTheRisk = false): PrivacyKeyPair {
    this.assertAlive();
    if (!iUnderstandTheRisk) {
      throw new Error(
        "exportKeys() exposes your raw spending key. " +
          "Call exportKeys(true) to acknowledge you understand the risk.",
      );
    }
    return {
      spendingKey: this.sk!,
      viewingKey: this.vk!,
      ownerHash: this._ownerHash,
    };
  }

  /**
   * Export only the viewing key and owner hash (safe to share for scanning).
   */
  exportViewingKeys(): { viewingKey: ViewingKey; ownerHash: Felt252 } {
    this.assertAlive();
    return {
      viewingKey: this.vk!,
      ownerHash: this._ownerHash,
    };
  }

  get spendingKey(): SpendingKey {
    this.assertAlive();
    return this.sk!;
  }

  get viewingKey(): ViewingKey {
    this.assertAlive();
    return this.vk!;
  }

  get ownerHash(): Felt252 {
    return this._ownerHash;
  }

  /**
   * Destroy key material. After calling this, the KeyManager instance is
   * permanently unusable. Any raw seed bytes are securely zeroed.
   *
   * JS BigInts are immutable and GC-managed, so we cannot overwrite them
   * in place. We null the references so (a) the GC can collect them sooner
   * and (b) any subsequent access throws immediately.
   */
  destroy(): void {
    if (this.destroyed) return;
    this.sk = null;
    this.vk = null;
    if (this.seedBytes) {
      zeroize(this.seedBytes);
      this.seedBytes = null;
    }
    this.destroyed = true;
  }

  /**
   * Whether this key manager has been destroyed.
   */
  get isDestroyed(): boolean {
    return this.destroyed;
  }
}
