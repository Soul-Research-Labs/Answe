import { describe, it, expect } from "vitest";
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
