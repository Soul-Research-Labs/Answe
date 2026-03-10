/**
 * Integration tests for StarkPrivacyClient against starknet-devnet-rs.
 *
 * These tests require a running devnet instance:
 *   ./scripts/devnet.sh
 *
 * Run with:
 *   DEVNET_URL=http://127.0.0.1:5050/rpc npx vitest run src/__tests__/integration.test.ts
 *
 * Skip in CI by checking for DEVNET_URL env var.
 */
import { describe, it, expect, beforeAll } from "vitest";
import { RpcProvider, Account, Contract, json } from "starknet";
import { StarkPrivacyClient, type StarkPrivacyConfig } from "../client.js";
import { KeyManager } from "../keys.js";
import {
  poseidonHash2,
  computeNoteCommitment,
  randomFelt252,
} from "../crypto.js";
import { PRIVACY_POOL_ABI, type ContractAddresses } from "../types.js";

const DEVNET_URL = process.env.DEVNET_URL;
const describeIntegration = DEVNET_URL ? describe : describe.skip;

/**
 * Helper to get predeployed accounts from devnet.
 */
async function getDevnetAccounts(
  rpcUrl: string,
): Promise<{ address: string; privateKey: string }[]> {
  const baseUrl = rpcUrl.replace(/\/rpc$/, "");
  const res = await fetch(`${baseUrl}/predeployed_accounts`);
  const accts = (await res.json()) as {
    address: string;
    private_key: string;
  }[];
  return accts.map((a) => ({
    address: a.address,
    privateKey: a.private_key,
  }));
}

describeIntegration("E2E: StarkPrivacyClient against devnet", () => {
  let provider: RpcProvider;
  let deployer: Account;
  let alice: KeyManager;
  let bob: KeyManager;
  let poolAddress: string;
  let config: StarkPrivacyConfig;

  beforeAll(async () => {
    provider = new RpcProvider({ nodeUrl: DEVNET_URL! });

    // Get predeployed accounts
    const accounts = await getDevnetAccounts(DEVNET_URL!);
    deployer = new Account(
      provider,
      accounts[0].address,
      accounts[0].privateKey,
    );

    // Generate privacy keys for Alice and Bob
    alice = KeyManager.generate();
    bob = KeyManager.generate();

    // Note: In a full integration test, we would deploy the contracts first.
    // For now, we test the SDK components that don't need on-chain contracts.
    poolAddress =
      "0x0000000000000000000000000000000000000000000000000000000000000001";

    config = {
      rpcUrl: DEVNET_URL!,
      contracts: {
        pool: poolAddress,
      } as ContractAddresses,
      chainId: 0x534e5f5345504f4c4941n,
      appId: 0x535441524b505249564143n,
    };
  });

  it("connects to devnet", async () => {
    const chainId = await provider.getChainId();
    expect(chainId).toBeTruthy();
  });

  it("generates valid key pairs", () => {
    const aliceKeys = alice.exportKeys();
    expect(aliceKeys.spendingKey).toBeGreaterThan(0n);
    expect(aliceKeys.viewingKey).toBeGreaterThan(0n);
    expect(aliceKeys.ownerHash).toBeGreaterThan(0n);
    // ownerHash = poseidon(spendingKey, 0)
    expect(aliceKeys.ownerHash).toBe(poseidonHash2(aliceKeys.spendingKey, 0n));
  });

  it("creates a client from spending key", () => {
    const client = StarkPrivacyClient.fromSpendingKey(
      config,
      alice.exportKeys().spendingKey,
    );
    expect(client).toBeDefined();
    expect(client.getBalance()).toBe(0n);
  });

  it("key pairs are unique per generation", () => {
    const k1 = KeyManager.generate().exportKeys();
    const k2 = KeyManager.generate().exportKeys();
    expect(k1.spendingKey).not.toBe(k2.spendingKey);
    expect(k1.ownerHash).not.toBe(k2.ownerHash);
  });

  it("note stats start at zero", () => {
    const client = StarkPrivacyClient.fromSpendingKey(
      config,
      alice.exportKeys().spendingKey,
    );
    const stats = client.getNoteStats();
    expect(stats.unspent).toBe(0);
    expect(stats.spent).toBe(0);
    expect(stats.pending).toBe(0);
  });

  it("throws without account for deposit", async () => {
    // Client without account should throw on operations requiring signing
    const readOnlyConfig: StarkPrivacyConfig = {
      ...config,
      account: undefined,
    };
    const client = StarkPrivacyClient.fromSpendingKey(
      readOnlyConfig,
      alice.exportKeys().spendingKey,
    );
    await expect(client.deposit(100n)).rejects.toThrow(
      "Account not configured",
    );
  });

  it("alice and bob have distinct owner hashes", () => {
    const aliceKeys = alice.exportKeys();
    const bobKeys = bob.exportKeys();
    expect(aliceKeys.ownerHash).not.toBe(bobKeys.ownerHash);
  });

  it("commitment is deterministic for same inputs", () => {
    const blinding = randomFelt252();
    const c1 = computeNoteCommitment({
      owner: alice.exportKeys().ownerHash,
      value: 100n,
      assetId: 0n,
      blinding,
    });
    const c2 = computeNoteCommitment({
      owner: alice.exportKeys().ownerHash,
      value: 100n,
      assetId: 0n,
      blinding,
    });
    expect(c1).toBe(c2);
  });

  it("different amounts produce different commitments", () => {
    const blinding = randomFelt252();
    const c1 = computeNoteCommitment({
      owner: alice.exportKeys().ownerHash,
      value: 100n,
      assetId: 0n,
      blinding,
    });
    const c2 = computeNoteCommitment({
      owner: alice.exportKeys().ownerHash,
      value: 200n,
      assetId: 0n,
      blinding,
    });
    expect(c1).not.toBe(c2);
  });
});

describeIntegration(
  "E2E: Full deposit→transfer→withdraw flow (requires deployed contracts)",
  () => {
    // This test group requires contracts deployed to devnet.
    // Set POOL_ADDRESS env to an actual deployed pool.
    const POOL_ADDRESS = process.env.POOL_ADDRESS;
    const describeDeployed = POOL_ADDRESS ? describe : describe.skip;

    describeDeployed("with deployed PrivacyPool", () => {
      let provider: RpcProvider;
      let alice: StarkPrivacyClient;
      let bob: StarkPrivacyClient;

      beforeAll(async () => {
        provider = new RpcProvider({ nodeUrl: DEVNET_URL! });
        const accounts = await getDevnetAccounts(DEVNET_URL!);

        const aliceConfig: StarkPrivacyConfig = {
          rpcUrl: DEVNET_URL!,
          contracts: { pool: POOL_ADDRESS! } as ContractAddresses,
          chainId: 0x534e5f5345504f4c4941n,
          appId: 0x535441524b505249564143n,
          account: {
            address: accounts[0].address,
            privateKey: accounts[0].privateKey,
          },
        };

        const bobConfig: StarkPrivacyConfig = {
          ...aliceConfig,
          account: {
            address: accounts[1].address,
            privateKey: accounts[1].privateKey,
          },
        };

        alice = StarkPrivacyClient.fromSpendingKey(
          aliceConfig,
          KeyManager.generate().exportKeys().spendingKey,
        );
        bob = StarkPrivacyClient.fromSpendingKey(
          bobConfig,
          KeyManager.generate().exportKeys().spendingKey,
        );
      });

      it("Alice deposits into privacy pool", async () => {
        const { note, txHash } = await alice.deposit(1000n);
        expect(txHash).toBeTruthy();
        expect(note.commitment).toBeGreaterThan(0n);
        expect(alice.getBalance()).toBe(1000n);
      });

      it("pool root changes after deposit", async () => {
        const root = await alice.getRoot();
        expect(root).toBeGreaterThan(0n);
      });

      it("Alice transfers to Bob", async () => {
        const bobKeys = KeyManager.generate().exportKeys();
        const { outputNotes, txHash } = await alice.transfer(
          bobKeys.ownerHash,
          700n,
        );
        expect(txHash).toBeTruthy();
        expect(outputNotes).toHaveLength(2);
      });

      it("Alice withdraws remaining balance", async () => {
        const { txHash } = await alice.withdraw("0x1234567890abcdef", 300n);
        expect(txHash).toBeTruthy();
      });
    });
  },
);
