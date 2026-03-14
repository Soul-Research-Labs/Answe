import { describe, it, expect } from "vitest";
import { deriveStealthAddress, tryScanNote } from "../stealth.js";
import { KeyManager } from "../keys.js";
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
    it("detects a note that belongs to us via real ECDH", () => {
      const recipient = KeyManager.fromSpendingKey(42n);
      const meta = makeMetaAddress(recipient);

      // Sender derives a stealth address using real ECDH
      const stealth = deriveStealthAddress(meta);

      // Recipient scans: tryScanNote should find a match
      const found = tryScanNote(
        stealth.ephemeralPubKey,
        recipient.viewingKey,
        meta.spendingPubKey,
        stealth.ownerHash,
      );
      expect(found).toBe(true);
    });

    it("rejects notes not belonging to us", () => {
      const recipient = KeyManager.fromSpendingKey(42n);
      const meta = makeMetaAddress(recipient);

      const stealth = deriveStealthAddress(meta);

      // Wrong owner hash
      const wrongOwner = 9999n;
      const found = tryScanNote(
        stealth.ephemeralPubKey,
        recipient.viewingKey,
        meta.spendingPubKey,
        wrongOwner,
      );
      expect(found).toBe(false);
    });

    it("rejects scan with wrong viewing key", () => {
      const recipient = KeyManager.fromSpendingKey(42n);
      const meta = makeMetaAddress(recipient);
      const stealth = deriveStealthAddress(meta);

      // Different user tries to scan with their own viewing key
      const other = KeyManager.fromSpendingKey(99n);
      const found = tryScanNote(
        stealth.ephemeralPubKey,
        other.viewingKey,
        meta.spendingPubKey,
        stealth.ownerHash,
      );
      expect(found).toBe(false);
    });
  });
});
