import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  EventIndexer,
  type IndexedDeposit,
  type IndexedNullifier,
} from "../indexer.js";

const RPC = "http://127.0.0.1:5050/rpc";
const POOL = "0x1234";

function makeDeposit(idx: number, commitment: bigint): IndexedDeposit {
  return {
    commitment,
    amount: 100n,
    assetId: 0n,
    leafIndex: idx,
    blockNumber: 100 + idx,
    txHash: `0x${idx.toString(16)}`,
  };
}

function makeNullifier(nf: bigint, block: number): IndexedNullifier {
  return { nullifier: nf, blockNumber: block, txHash: "0xABC" };
}

describe("EventIndexer", () => {
  it("starts with empty state", () => {
    const indexer = new EventIndexer(RPC, POOL);
    expect(indexer.getDeposits()).toEqual([]);
    expect(indexer.getNullifiers()).toEqual([]);
    expect(indexer.getStealthMatches()).toEqual([]);
    const p = indexer.getProgress();
    expect(p.depositsFound).toBe(0);
    expect(p.lastBlockScanned).toBe(0);
  });

  it("tracks added deposits", () => {
    const indexer = new EventIndexer(RPC, POOL);
    indexer.addDeposit(makeDeposit(0, 0xaaan));
    indexer.addDeposit(makeDeposit(1, 0xbbbn));
    expect(indexer.getDeposits().length).toBe(2);
    expect(indexer.getProgress().depositsFound).toBe(2);
  });

  it("tracks added nullifiers", () => {
    const indexer = new EventIndexer(RPC, POOL);
    indexer.addNullifier(makeNullifier(0x111n, 100));
    indexer.addNullifier(makeNullifier(0x222n, 101));
    expect(indexer.getNullifiers().length).toBe(2);
  });

  it("returns ordered commitments by leaf index", () => {
    const indexer = new EventIndexer(RPC, POOL);
    indexer.addDeposit(makeDeposit(2, 0xcccn));
    indexer.addDeposit(makeDeposit(0, 0xaaan));
    indexer.addDeposit(makeDeposit(1, 0xbbbn));

    const commitments = indexer.getOrderedCommitments();
    expect(commitments).toEqual([0xaaan, 0xbbbn, 0xcccn]);
  });

  it("filters own deposits by known commitments", () => {
    const indexer = new EventIndexer(RPC, POOL);
    indexer.addDeposit(makeDeposit(0, 0xaaan));
    indexer.addDeposit(makeDeposit(1, 0xbbbn));
    indexer.addDeposit(makeDeposit(2, 0xcccn));

    const known = new Set([0xaaan, 0xcccn]);
    const own = indexer.filterOwnDeposits(known);
    expect(own.length).toBe(2);
    expect(own.map((d) => d.commitment)).toContain(0xaaan);
    expect(own.map((d) => d.commitment)).toContain(0xcccn);
  });

  it("detects spent nullifiers", () => {
    const indexer = new EventIndexer(RPC, POOL);
    indexer.addNullifier(makeNullifier(0x111n, 100));
    indexer.addNullifier(makeNullifier(0x333n, 102));

    const myNullifiers = [0x111n, 0x222n, 0x333n];
    const spent = indexer.getSpentNullifiers(myNullifiers);
    expect(spent).toEqual([0x111n, 0x333n]);
  });

  it("updates last block scanned", () => {
    const indexer = new EventIndexer(RPC, POOL);
    indexer.setLastBlockScanned(500);
    expect(indexer.getProgress().lastBlockScanned).toBe(500);
  });

  it("returns copies of internal arrays", () => {
    const indexer = new EventIndexer(RPC, POOL);
    indexer.addDeposit(makeDeposit(0, 0xaaan));
    const deps = indexer.getDeposits();
    deps.push(makeDeposit(1, 0xbbbn));
    // Internal state should be unaffected
    expect(indexer.getDeposits().length).toBe(1);
  });

  it("isOwnDeposit checks known set", () => {
    const indexer = new EventIndexer(RPC, POOL);
    const known = new Set([0xaaan]);
    expect(indexer.isOwnDeposit(0xaaan, known)).toBe(true);
    expect(indexer.isOwnDeposit(0xbbbn, known)).toBe(false);
  });

  it("scanStealth throws without registry address", async () => {
    const indexer = new EventIndexer(RPC, POOL);
    await expect(indexer.scanStealth(0n, 0n)).rejects.toThrow(
      "No stealth registry",
    );
  });
});

// ─── scanBlocks with mocked provider ────────────────────────────

describe("EventIndexer.scanBlocks (mocked)", () => {
  function createMockedIndexer(): EventIndexer {
    const indexer = new EventIndexer(RPC, POOL);

    // Mock the provider's methods
    const provider = (indexer as any).provider;

    provider.getBlockLatestAccepted = vi.fn().mockResolvedValue({
      block_number: 200,
    });

    // Deposit events response
    const depositResponse = {
      events: [
        {
          block_number: 100,
          transaction_hash: "0xdep1",
          keys: [
            "0x9149d2123147c5f43d258257fef0b7b969db78269369ebcf5c3f201e16f2b",
            "0xAABB", // commitment
          ],
          data: [
            "0x0", // leafIndex
            "0x64", // amount low (100)
            "0x0", // amount high
            "0x0", // assetId
          ],
        },
        {
          block_number: 150,
          transaction_hash: "0xdep2",
          keys: [
            "0x9149d2123147c5f43d258257fef0b7b969db78269369ebcf5c3f201e16f2b",
            "0xCCDD",
          ],
          data: ["0x1", "0xC8", "0x0", "0x0"], // leafIndex 1, amount 200
        },
      ],
      continuation_token: undefined,
    };

    // Nullifier events response
    const nullifierResponse = {
      events: [
        {
          block_number: 120,
          transaction_hash: "0xwd1",
          keys: [
            "0x2c70efff30c4d1a69fdd061e0e5527d940507e69de9a79f29d0705e8ccc3d1a",
            "0x1111", // nf1
            "0x2222", // nf2
          ],
          data: [],
        },
      ],
      continuation_token: undefined,
    };

    provider.getEvents = vi.fn().mockImplementation((params: any) => {
      const key = params.keys?.[0]?.[0] ?? "";
      if (key.includes("9149d2")) return Promise.resolve(depositResponse);
      if (key.includes("2c70ef")) return Promise.resolve(nullifierResponse);
      return Promise.resolve({ events: [], continuation_token: undefined });
    });

    return indexer;
  }

  it("scans blocks and populates deposits and nullifiers", async () => {
    const indexer = createMockedIndexer();
    const result = await indexer.scanBlocks(1, 200);

    expect(result.deposits).toBe(2);
    expect(result.nullifiers).toBe(2);
    expect(indexer.getDeposits().length).toBe(2);
    expect(indexer.getNullifiers().length).toBe(2);
    expect(indexer.getProgress().lastBlockScanned).toBe(200);
  });

  it("parses deposit amounts correctly", async () => {
    const indexer = createMockedIndexer();
    await indexer.scanBlocks(1, 200);

    const deposits = indexer.getDeposits();
    expect(deposits[0].commitment).toBe(0xaabbn);
    expect(deposits[0].amount).toBe(100n);
    expect(deposits[0].leafIndex).toBe(0);
    expect(deposits[1].commitment).toBe(0xccddn);
    expect(deposits[1].amount).toBe(200n);
    expect(deposits[1].leafIndex).toBe(1);
  });

  it("parses nullifiers correctly", async () => {
    const indexer = createMockedIndexer();
    await indexer.scanBlocks(1, 200);

    const nullifiers = indexer.getNullifiers();
    expect(nullifiers[0].nullifier).toBe(0x1111n);
    expect(nullifiers[1].nullifier).toBe(0x2222n);
  });

  it("uses latest block when toBlock is omitted", async () => {
    const indexer = createMockedIndexer();
    await indexer.scanBlocks(1);

    expect(indexer.getProgress().lastBlockScanned).toBe(200);
  });

  it("returns zero counts when startBlock > endBlock", async () => {
    const indexer = createMockedIndexer();
    const result = await indexer.scanBlocks(500, 200);

    expect(result.deposits).toBe(0);
    expect(result.nullifiers).toBe(0);
  });

  it("incremental scan resumes from lastBlockScanned", async () => {
    const indexer = createMockedIndexer();
    indexer.setLastBlockScanned(100);

    // scanBlocks with no fromBlock uses lastBlockScanned + 1
    const provider = (indexer as any).provider;
    const getEventsSpy = provider.getEvents;

    await indexer.scanBlocks();

    // Should have been called with from_block > 100
    const calls = getEventsSpy.mock.calls;
    expect(calls.length).toBeGreaterThan(0);
    const firstCall = calls[0][0];
    expect(firstCall.from_block.block_number).toBe(101);
  });
});

// ─── Edge cases ──────────────────────────────────────────────────

describe("EventIndexer edge cases", () => {
  it("handles high u256 amounts (amountHigh != 0)", () => {
    const indexer = new EventIndexer(RPC, POOL);
    // Simulate a deposit with high portion set
    // amount = low + (high << 128)
    const dep: IndexedDeposit = {
      commitment: 0xffn,
      amount: 1n + (2n << 128n), // 2 * 2^128 + 1
      assetId: 0n,
      leafIndex: 0,
      blockNumber: 1,
      txHash: "0x1",
    };
    indexer.addDeposit(dep);
    expect(indexer.getDeposits()[0].amount).toBe(1n + (2n << 128n));
  });

  it("handles empty events gracefully", async () => {
    const indexer = new EventIndexer(RPC, POOL);
    const provider = (indexer as any).provider;
    provider.getBlockLatestAccepted = vi.fn().mockResolvedValue({
      block_number: 10,
    });
    provider.getEvents = vi.fn().mockResolvedValue({
      events: [],
      continuation_token: undefined,
    });

    const result = await indexer.scanBlocks(1, 10);
    expect(result.deposits).toBe(0);
    expect(result.nullifiers).toBe(0);
    expect(indexer.getProgress().lastBlockScanned).toBe(10);
  });

  it("handles continuation token pagination", async () => {
    const indexer = new EventIndexer(RPC, POOL);
    const provider = (indexer as any).provider;
    provider.getBlockLatestAccepted = vi.fn().mockResolvedValue({
      block_number: 10,
    });

    let callCount = 0;
    provider.getEvents = vi.fn().mockImplementation(() => {
      callCount++;
      if (callCount === 1) {
        return Promise.resolve({
          events: [
            {
              block_number: 5,
              transaction_hash: "0x1",
              keys: [
                "0x9149d2123147c5f43d258257fef0b7b969db78269369ebcf5c3f201e16f2b",
                "0xAA",
              ],
              data: ["0x0", "0x1", "0x0", "0x0"],
            },
          ],
          continuation_token: "page2",
        });
      }
      return Promise.resolve({
        events: [],
        continuation_token: undefined,
      });
    });

    const result = await indexer.scanBlocks(1, 10);
    expect(result.deposits).toBe(1);
    // getEvents called at least twice (first page + continuation + nullifiers)
    expect(callCount).toBeGreaterThanOrEqual(2);
  });
});
