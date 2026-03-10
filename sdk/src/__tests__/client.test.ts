/**
 * Unit tests for StarkPrivacyClient — pure logic tests (no network).
 */
import { describe, it, expect } from "vitest";
import { StarkPrivacyClient, type StarkPrivacyConfig } from "../client.js";
import { KeyManager } from "../keys.js";
import { type ContractAddresses } from "../types.js";

const dummyConfig: StarkPrivacyConfig = {
  rpcUrl: "http://localhost:5050/rpc",
  contracts: {
    pool: "0x01",
    stealthRegistry: "0x02",
    stealthFactory: "0x03",
    l1Bridge: "0x04",
    epochManager: "0x05",
    complianceOracle: "0x06",
  } as ContractAddresses,
  chainId: 1n,
  appId: 1n,
};

const readOnlyConfig: StarkPrivacyConfig = {
  ...dummyConfig,
  account: undefined,
};

describe("StarkPrivacyClient", () => {
  describe("construction", () => {
    it("creates client from spending key", () => {
      const km = KeyManager.generate();
      const client = StarkPrivacyClient.fromSpendingKey(
        dummyConfig,
        km.exportKeys().spendingKey,
      );
      expect(client).toBeInstanceOf(StarkPrivacyClient);
    });

    it("initial balance is zero", () => {
      const client = StarkPrivacyClient.fromSpendingKey(
        dummyConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      expect(client.getBalance()).toBe(0n);
    });

    it("initial note stats are zero", () => {
      const client = StarkPrivacyClient.fromSpendingKey(
        dummyConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      const stats = client.getNoteStats();
      expect(stats).toEqual({ unspent: 0, spent: 0, pending: 0 });
    });
  });

  describe("account requirement", () => {
    it("deposit throws without account", async () => {
      const client = StarkPrivacyClient.fromSpendingKey(
        readOnlyConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      await expect(client.deposit(100n)).rejects.toThrow(
        "Account not configured",
      );
    });

    it("transfer throws without account", async () => {
      const client = StarkPrivacyClient.fromSpendingKey(
        readOnlyConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      await expect(client.transfer(1n, 100n)).rejects.toThrow(
        "Account not configured",
      );
    });

    it("withdraw throws without account", async () => {
      const client = StarkPrivacyClient.fromSpendingKey(
        readOnlyConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      await expect(client.withdraw("0x1", 100n)).rejects.toThrow(
        "Account not configured",
      );
    });

    it("registerStealthMetaAddress throws without account", async () => {
      const client = StarkPrivacyClient.fromSpendingKey(
        readOnlyConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      await expect(client.registerStealthMetaAddress(1n, 2n)).rejects.toThrow(
        "Account not configured",
      );
    });

    it("bridgeToL1 throws without account", async () => {
      const client = StarkPrivacyClient.fromSpendingKey(
        readOnlyConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      await expect(client.bridgeToL1(1n, 2n, 100n)).rejects.toThrow(
        "Account not configured",
      );
    });
  });

  describe("contract requirement", () => {
    it("requireContract throws for missing contract", async () => {
      const partialConfig: StarkPrivacyConfig = {
        ...dummyConfig,
        contracts: { pool: "0x01" } as ContractAddresses,
      };
      const client = StarkPrivacyClient.fromSpendingKey(
        partialConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      // scanStealthNotes requires stealthRegistry
      await expect(client.scanStealthNotes(1n)).rejects.toThrow(
        "Contract address for 'stealthRegistry' not configured",
      );
    });

    it("getCurrentEpoch throws without epochManager", async () => {
      const partialConfig: StarkPrivacyConfig = {
        ...dummyConfig,
        contracts: { pool: "0x01" } as ContractAddresses,
      };
      const client = StarkPrivacyClient.fromSpendingKey(
        partialConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      await expect(client.getCurrentEpoch()).rejects.toThrow(
        "Contract address for 'epochManager' not configured",
      );
    });

    it("getEpochRoot throws without epochManager", async () => {
      const partialConfig: StarkPrivacyConfig = {
        ...dummyConfig,
        contracts: { pool: "0x01" } as ContractAddresses,
      };
      const client = StarkPrivacyClient.fromSpendingKey(
        partialConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      await expect(client.getEpochRoot(1n)).rejects.toThrow(
        "Contract address for 'epochManager' not configured",
      );
    });
  });

  describe("balance tracking", () => {
    it("getBalance returns 0n for unknown asset", () => {
      const client = StarkPrivacyClient.fromSpendingKey(
        dummyConfig,
        KeyManager.generate().exportKeys().spendingKey,
      );
      expect(client.getBalance(999n)).toBe(0n);
    });
  });
});
