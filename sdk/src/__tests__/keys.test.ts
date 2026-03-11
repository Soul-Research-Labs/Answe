import { describe, it, expect } from "vitest";
import { KeyManager } from "../keys.js";
import { poseidonHash2 } from "../crypto.js";

describe("KeyManager", () => {
  describe("generate", () => {
    it("creates a key manager with all fields populated", () => {
      const km = KeyManager.generate();
      expect(typeof km.spendingKey).toBe("bigint");
      expect(typeof km.viewingKey).toBe("bigint");
      expect(typeof km.ownerHash).toBe("bigint");
      expect(km.spendingKey).toBeGreaterThan(0n);
    });

    it("generates different keys each time", () => {
      const km1 = KeyManager.generate();
      const km2 = KeyManager.generate();
      expect(km1.spendingKey).not.toBe(km2.spendingKey);
    });
  });

  describe("fromSpendingKey", () => {
    it("deterministically derives viewing key and owner hash", () => {
      const sk = 42n;
      const km1 = KeyManager.fromSpendingKey(sk);
      const km2 = KeyManager.fromSpendingKey(sk);
      expect(km1.spendingKey).toBe(km2.spendingKey);
      expect(km1.viewingKey).toBe(km2.viewingKey);
      expect(km1.ownerHash).toBe(km2.ownerHash);
    });

    it("viewing key = Poseidon(sk, 1)", () => {
      const sk = 42n;
      const km = KeyManager.fromSpendingKey(sk);
      expect(km.viewingKey).toBe(poseidonHash2(sk, 1n));
    });

    it("owner hash = Poseidon(sk, 0)", () => {
      const sk = 42n;
      const km = KeyManager.fromSpendingKey(sk);
      expect(km.ownerHash).toBe(poseidonHash2(sk, 0n));
    });
  });

  describe("exportKeys", () => {
    it("returns all key components when risk acknowledged", () => {
      const km = KeyManager.generate();
      const keys = km.exportKeys(true);
      expect(keys.spendingKey).toBe(km.spendingKey);
      expect(keys.viewingKey).toBe(km.viewingKey);
      expect(keys.ownerHash).toBe(km.ownerHash);
    });

    it("throws without risk acknowledgement", () => {
      const km = KeyManager.generate();
      expect(() => km.exportKeys()).toThrow("spending key");
    });
  });
});
