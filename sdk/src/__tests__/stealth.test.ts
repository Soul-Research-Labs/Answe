import { describe, it, expect } from "vitest";
import { deriveStealthAddress, tryScanNote } from "../stealth.js";
import { KeyManager } from "../keys.js";
import { poseidonHash2 } from "../crypto.js";
import { ec, encode } from "starknet";

describe("stealth addresses", () => {
  // Helper: create a "meta-address" from a key manager.
  // In production, pubkeys would be on STARK curve; for testing we use
  // the starkKey derived from the private key.
  function makeMetaAddress(km: KeyManager) {
    const spendingPubKey = BigInt(
      ec.starkCurve.getStarkKey("0x" + km.spendingKey.toString(16)),
    );
    const viewingPubKey = BigInt(
      ec.starkCurve.getStarkKey("0x" + km.viewingKey.toString(16)),
    );
    return { spendingPubKey, viewingPubKey };
  }

  describe("deriveStealthAddress", () => {
    it("produces non-zero owner hash", () => {
      const recipient = KeyManager.fromSpendingKey(42n);
      const meta = makeMetaAddress(recipient);
      const stealth = deriveStealthAddress(meta);
      expect(stealth.ownerHash).toBeGreaterThan(0n);
      expect(stealth.ephemeralPubKey).toBeGreaterThan(0n);
      expect(stealth.sharedSecret).toBeGreaterThan(0n);
    });

    it("each derivation produces a different address", () => {
      const recipient = KeyManager.fromSpendingKey(42n);
      const meta = makeMetaAddress(recipient);
      const s1 = deriveStealthAddress(meta);
      const s2 = deriveStealthAddress(meta);
      // Different ephemeral keys each time
      expect(s1.ephemeralPubKey).not.toBe(s2.ephemeralPubKey);
      expect(s1.ownerHash).not.toBe(s2.ownerHash);
    });
  });

  describe("tryScanNote", () => {
    it("simplified stealth scanning: Poseidon-based shared secret", () => {
      const viewingKey = 42n;
      const spendingPubKey = 100n;
      const ephPubKey = 200n;

      // Manually compute expected owner for the "simplified" model
      const sharedSecret = poseidonHash2(viewingKey, ephPubKey);
      const expectedOwner = poseidonHash2(sharedSecret, spendingPubKey);

      // tryScanNote should detect this note as ours
      expect(
        tryScanNote(ephPubKey, viewingKey, spendingPubKey, expectedOwner),
      ).toBe(true);
    });

    it("rejects notes not belonging to us", () => {
      const viewingKey = 42n;
      const spendingPubKey = 100n;
      const ephPubKey = 200n;
      const wrongOwner = 9999n;

      expect(
        tryScanNote(ephPubKey, viewingKey, spendingPubKey, wrongOwner),
      ).toBe(false);
    });
  });
});
