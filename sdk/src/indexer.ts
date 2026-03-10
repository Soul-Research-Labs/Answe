/**
 * Event indexer — scans on-chain events to detect deposits, transfers,
 * and stealth payments relevant to the user.
 *
 * Production would use a persistent DB and WebSocket subscriptions;
 * this module provides the core scanning logic that can be backed by
 * any block fetcher.
 */
import { RpcProvider, Contract } from "starknet";
import { poseidonHash2 } from "./crypto.js";
import { tryScanNote, type MetaAddress } from "./stealth.js";
import type { Felt252 } from "./types.js";
import { PRIVACY_POOL_ABI, STEALTH_REGISTRY_ABI } from "./types.js";

// ─── Types ───────────────────────────────────────────────────────

export interface IndexedDeposit {
  commitment: Felt252;
  amount: bigint;
  assetId: Felt252;
  leafIndex: number;
  blockNumber: number;
  txHash: string;
}

export interface IndexedNullifier {
  nullifier: Felt252;
  blockNumber: number;
  txHash: string;
}

export interface StealthMatch {
  ephemeralPubKey: Felt252;
  commitment: Felt252;
  index: number;
}

export interface ScanProgress {
  lastBlockScanned: number;
  depositsFound: number;
  nullifiersFound: number;
  stealthMatches: number;
}

// ─── Event Indexer ───────────────────────────────────────────────

export class EventIndexer {
  private provider: RpcProvider;
  private poolAddress: string;
  private stealthAddress?: string;
  private deposits: IndexedDeposit[] = [];
  private nullifiers: IndexedNullifier[] = [];
  private stealthMatches: StealthMatch[] = [];
  private lastBlockScanned = 0;

  constructor(rpcUrl: string, poolAddress: string, stealthAddress?: string) {
    this.provider = new RpcProvider({ nodeUrl: rpcUrl });
    this.poolAddress = poolAddress;
    this.stealthAddress = stealthAddress;
  }

  /**
   * Get all indexed deposits.
   */
  getDeposits(): IndexedDeposit[] {
    return [...this.deposits];
  }

  /**
   * Get all indexed nullifiers.
   */
  getNullifiers(): IndexedNullifier[] {
    return [...this.nullifiers];
  }

  /**
   * Get stealth matches found during scanning.
   */
  getStealthMatches(): StealthMatch[] {
    return [...this.stealthMatches];
  }

  /**
   * Get current scan progress.
   */
  getProgress(): ScanProgress {
    return {
      lastBlockScanned: this.lastBlockScanned,
      depositsFound: this.deposits.length,
      nullifiersFound: this.nullifiers.length,
      stealthMatches: this.stealthMatches.length,
    };
  }

  /**
   * Get all leaf commitments in insertion order —
   * used to populate a ClientMerkleTree for proof generation.
   */
  getOrderedCommitments(): Felt252[] {
    return this.deposits
      .sort((a, b) => a.leafIndex - b.leafIndex)
      .map((d) => d.commitment);
  }

  /**
   * Check if a commitment matches any of the user's notes.
   *
   * @param commitment - The commitment to check.
   * @param ownerHash - The user's owner hash (Poseidon(sk, 0)).
   * @param knownCommitments - Set of commitments the user owns.
   */
  isOwnDeposit(commitment: Felt252, knownCommitments: Set<bigint>): boolean {
    return knownCommitments.has(commitment);
  }

  /**
   * Filter deposits to only those belonging to the user.
   */
  filterOwnDeposits(knownCommitments: Set<bigint>): IndexedDeposit[] {
    return this.deposits.filter((d) => knownCommitments.has(d.commitment));
  }

  /**
   * Check which of the user's notes have been spent.
   */
  getSpentNullifiers(noteNullifiers: Felt252[]): Felt252[] {
    const indexed = new Set(this.nullifiers.map((n) => n.nullifier));
    return noteNullifiers.filter((nf) => indexed.has(nf));
  }

  /**
   * Scan stealth registry for incoming payments.
   * Uses trial decryption with the user's viewing key.
   */
  async scanStealth(
    viewingKey: Felt252,
    spendingPubKey: Felt252,
    fromIndex: number = 0,
  ): Promise<StealthMatch[]> {
    if (!this.stealthAddress) {
      throw new Error("No stealth registry address configured");
    }

    const registry = new Contract(
      STEALTH_REGISTRY_ABI as any,
      this.stealthAddress,
      this.provider,
    );

    const countResult = await registry.call("get_ephemeral_count");
    const count = Number(BigInt(countResult.toString()));
    const newMatches: StealthMatch[] = [];

    for (let i = fromIndex; i < count; i++) {
      const result = await registry.call("get_ephemeral_at", [i.toString()]);
      const [ephPubStr, commitmentStr] = Array.isArray(result)
        ? result
        : [result];
      const ephPub = BigInt(ephPubStr.toString());
      const commitment = BigInt(commitmentStr.toString());

      if (tryScanNote(ephPub, viewingKey, spendingPubKey, commitment)) {
        const match: StealthMatch = {
          ephemeralPubKey: ephPub,
          commitment,
          index: i,
        };
        newMatches.push(match);
        this.stealthMatches.push(match);
      }
    }

    return newMatches;
  }

  /**
   * Add a deposit event manually (for testing or custom event sources).
   */
  addDeposit(deposit: IndexedDeposit): void {
    this.deposits.push(deposit);
  }

  /**
   * Add a nullifier event manually (for testing or custom event sources).
   */
  addNullifier(nullifier: IndexedNullifier): void {
    this.nullifiers.push(nullifier);
  }

  /**
   * Update the last scanned block.
   */
  setLastBlockScanned(block: number): void {
    this.lastBlockScanned = block;
  }
}
