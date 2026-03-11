/**
 * Event indexer — scans on-chain events to detect deposits, transfers,
 * and stealth payments relevant to the user.
 *
 * Provides both manual injection (for testing) and real block scanning
 * via `provider.getEvents()`.
 */
import { RpcProvider, Contract, events, num } from "starknet";
import { poseidonHash2 } from "./crypto.js";
import { tryScanNote, type MetaAddress } from "./stealth.js";
import type { Felt252 } from "./types.js";
import { PRIVACY_POOL_ABI, STEALTH_REGISTRY_ABI } from "./types.js";

// ─── Types ───────────────────────────────────────────────────────

/** A deposit event parsed from on-chain data. */
export interface IndexedDeposit {
  commitment: Felt252;
  amount: bigint;
  assetId: Felt252;
  leafIndex: number;
  blockNumber: number;
  txHash: string;
}

/** A nullifier event parsed from on-chain data. */
export interface IndexedNullifier {
  nullifier: Felt252;
  blockNumber: number;
  txHash: string;
}

/** A stealth payment match found during scanning. */
export interface StealthMatch {
  ephemeralPubKey: Felt252;
  commitment: Felt252;
  index: number;
}

/** Progress metrics for the indexer's scanning state. */
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
   * Scan blockchain blocks for deposit and nullifier events.
   * Uses `starknet_getEvents` RPC to fetch events in paginated batches.
   *
   * @param fromBlock - Start block number (inclusive). Defaults to lastBlockScanned + 1.
   * @param toBlock - End block number (inclusive). Defaults to "latest".
   * @param chunkSize - Number of blocks per RPC request (default: 1000).
   */
  async scanBlocks(
    fromBlock?: number,
    toBlock?: number | "latest",
    chunkSize = 1000,
  ): Promise<{ deposits: number; nullifiers: number }> {
    const startBlock = fromBlock ?? this.lastBlockScanned + 1;

    // Resolve "latest" to an actual block number
    let endBlock: number;
    if (toBlock === undefined || toBlock === "latest") {
      const latest = await this.provider.getBlockLatestAccepted();
      endBlock = latest.block_number;
    } else {
      endBlock = toBlock;
    }

    if (startBlock > endBlock) {
      return { deposits: 0, nullifiers: 0 };
    }

    let depositsFound = 0;
    let nullifiersFound = 0;

    // Deposit event key: sn_keccak("Deposit")
    const DEPOSIT_KEY =
      "0x9149d2123147c5f43d258257fef0b7b969db78269369ebcf5c3f201e16f2b";
    // Withdrawal event key: sn_keccak("Withdrawal")
    const WITHDRAWAL_KEY =
      "0x2c70efff30c4d1a69fdd061e0e5527d940507e69de9a79f29d0705e8ccc3d1a";

    let currentFrom = startBlock;
    while (currentFrom <= endBlock) {
      const currentTo = Math.min(currentFrom + chunkSize - 1, endBlock);

      // Scan deposit events
      let continuationToken: string | undefined;
      do {
        const resp = await this.provider.getEvents({
          from_block: { block_number: currentFrom },
          to_block: { block_number: currentTo },
          address: this.poolAddress,
          keys: [[DEPOSIT_KEY]],
          chunk_size: 100,
          continuation_token: continuationToken,
        });

        for (const event of resp.events) {
          const blockNum = event.block_number ?? currentTo;
          const txHash = event.transaction_hash ?? "0x0";
          // Deposit event data: [commitment_key, leaf_index, amount_low, amount_high, asset_id]
          if (event.keys.length >= 2 && event.data.length >= 4) {
            const commitment = BigInt(event.keys[1]); // commitment is #[key]
            const leafIndex = Number(BigInt(event.data[0]));
            const amountLow = BigInt(event.data[1]);
            const amountHigh = BigInt(event.data[2]);
            const amount = amountLow + (amountHigh << 128n);
            const assetId = BigInt(event.data[3]);

            this.deposits.push({
              commitment,
              amount,
              assetId,
              leafIndex,
              blockNumber: blockNum,
              txHash,
            });
            depositsFound++;
          }
        }

        continuationToken = resp.continuation_token;
      } while (continuationToken);

      // Scan withdrawal/transfer events for nullifiers
      let nullToken: string | undefined;
      do {
        const resp = await this.provider.getEvents({
          from_block: { block_number: currentFrom },
          to_block: { block_number: currentTo },
          address: this.poolAddress,
          keys: [[WITHDRAWAL_KEY]],
          chunk_size: 100,
          continuation_token: nullToken,
        });

        for (const event of resp.events) {
          const blockNum = event.block_number ?? currentTo;
          const txHash = event.transaction_hash ?? "0x0";
          // Withdrawal event keys: [event_key, nullifier_1, nullifier_2]
          if (event.keys.length >= 3) {
            const nf1 = BigInt(event.keys[1]);
            const nf2 = BigInt(event.keys[2]);
            this.nullifiers.push({
              nullifier: nf1,
              blockNumber: blockNum,
              txHash,
            });
            this.nullifiers.push({
              nullifier: nf2,
              blockNumber: blockNum,
              txHash,
            });
            nullifiersFound += 2;
          }
        }

        nullToken = resp.continuation_token;
      } while (nullToken);

      currentFrom = currentTo + 1;
    }

    this.lastBlockScanned = endBlock;
    return { deposits: depositsFound, nullifiers: nullifiersFound };
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
