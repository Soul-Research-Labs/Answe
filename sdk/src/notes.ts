/**
 * Note management — tracks private notes (UTXOs) owned by the user.
 *
 * Handles:
 * - Creating new notes with proper blinding
 * - Tracking note status (unspent, spent, pending)
 * - Coin selection for transfers/withdrawals
 * - Computing commitments and nullifiers
 */
import {
  computeNoteCommitment,
  computeNullifier,
  randomFelt252,
  type NoteInput,
} from "./crypto.js";
import type { Felt252 } from "./types.js";

export type NoteStatus = "unspent" | "spent" | "pending";

export interface PrivacyNote {
  /** Unique local identifier. */
  id: string;
  /** Owner hash = Poseidon(sk, 0). */
  owner: Felt252;
  /** Value in the note. */
  value: bigint;
  /** Asset ID (0 = native). */
  assetId: Felt252;
  /** Random blinding factor. */
  blinding: Felt252;
  /** Computed commitment = Poseidon(owner, value, asset_id, blinding). */
  commitment: Felt252;
  /** Leaf index in the Merkle tree (set after deposit confirmation). */
  leafIndex?: number;
  /** Current status. */
  status: NoteStatus;
  /** Timestamp of creation. */
  createdAt: number;
}

/**
 * Manages the user's local note set.
 */
export class NoteManager {
  private notes: Map<string, PrivacyNote> = new Map();
  private nextId = 0;

  /**
   * Create a new note for a deposit or transfer output.
   */
  createNote(
    ownerHash: Felt252,
    value: bigint,
    assetId: Felt252 = 0n,
  ): PrivacyNote {
    const blinding = randomFelt252();
    const commitment = computeNoteCommitment({
      owner: ownerHash,
      value,
      assetId,
      blinding,
    });

    const note: PrivacyNote = {
      id: `note_${this.nextId++}`,
      owner: ownerHash,
      value,
      assetId,
      blinding,
      commitment,
      status: "unspent",
      createdAt: Date.now(),
    };

    this.notes.set(note.id, note);
    return note;
  }

  /**
   * Import an existing note (e.g., from backup or scanning).
   */
  importNote(params: {
    owner: Felt252;
    value: bigint;
    assetId: Felt252;
    blinding: Felt252;
    leafIndex?: number;
  }): PrivacyNote {
    const commitment = computeNoteCommitment({
      owner: params.owner,
      value: params.value,
      assetId: params.assetId,
      blinding: params.blinding,
    });

    const note: PrivacyNote = {
      id: `note_${this.nextId++}`,
      owner: params.owner,
      value: params.value,
      assetId: params.assetId,
      blinding: params.blinding,
      commitment,
      leafIndex: params.leafIndex,
      status: "unspent",
      createdAt: Date.now(),
    };

    this.notes.set(note.id, note);
    return note;
  }

  /**
   * Set a note's leaf index once the deposit/transfer is confirmed on-chain.
   */
  confirmNote(noteId: string, leafIndex: number): void {
    const note = this.notes.get(noteId);
    if (!note) throw new Error(`Note ${noteId} not found`);
    note.leafIndex = leafIndex;
  }

  /**
   * Mark notes as spent after a successful transfer or withdrawal.
   */
  markSpent(noteIds: string[]): void {
    for (const id of noteIds) {
      const note = this.notes.get(id);
      if (!note) throw new Error(`Note ${id} not found`);
      note.status = "spent";
    }
  }

  /**
   * Get all unspent notes, optionally filtered by asset.
   */
  getUnspent(assetId?: Felt252): PrivacyNote[] {
    const result: PrivacyNote[] = [];
    for (const note of this.notes.values()) {
      if (note.status !== "unspent") continue;
      if (assetId !== undefined && note.assetId !== assetId) continue;
      result.push(note);
    }
    return result;
  }

  /**
   * Compute total unspent balance for a given asset.
   */
  getBalance(assetId: Felt252 = 0n): bigint {
    return this.getUnspent(assetId).reduce((sum, note) => sum + note.value, 0n);
  }

  /**
   * Select notes for a transfer or withdrawal (greedy largest-first).
   *
   * Returns exactly 2 notes (padding with a zero-value note if needed)
   * since the circuit requires 2-in-2-out.
   */
  selectNotes(
    amount: bigint,
    assetId: Felt252 = 0n,
    ownerHash: Felt252 = 0n,
  ): [PrivacyNote, PrivacyNote] {
    const available = this.getUnspent(assetId)
      .filter((n) => n.leafIndex !== undefined) // only confirmed notes
      .sort((a, b) => (b.value > a.value ? 1 : b.value < a.value ? -1 : 0));

    if (available.length === 0) {
      throw new Error("No unspent notes available");
    }

    // Try single note
    const single = available.find((n) => n.value >= amount);
    if (single) {
      // Pad with a zero-value dummy note
      const dummy = this.createDummyNote(ownerHash, assetId);
      return [single, dummy];
    }

    // Try two notes
    for (let i = 0; i < available.length; i++) {
      for (let j = i + 1; j < available.length; j++) {
        if (available[i].value + available[j].value >= amount) {
          return [available[i], available[j]];
        }
      }
    }

    throw new Error(
      `Insufficient balance: need ${amount}, have ${this.getBalance(assetId)}`,
    );
  }

  /**
   * Compute nullifiers for a pair of notes.
   */
  computeNullifiers(
    spendingKey: Felt252,
    notes: [PrivacyNote, PrivacyNote],
    chainId: Felt252,
    appId: Felt252,
  ): [Felt252, Felt252] {
    return [
      computeNullifier(spendingKey, notes[0].commitment, chainId, appId),
      computeNullifier(spendingKey, notes[1].commitment, chainId, appId),
    ];
  }

  /**
   * Get the NoteInput representation for crypto operations.
   */
  toNoteInput(note: PrivacyNote): NoteInput {
    return {
      owner: note.owner,
      value: note.value,
      assetId: note.assetId,
      blinding: note.blinding,
    };
  }

  /**
   * Export all notes for backup/persistence.
   */
  exportNotes(): PrivacyNote[] {
    return Array.from(this.notes.values());
  }

  /**
   * Get the count of notes by status.
   */
  getStats(): { unspent: number; spent: number; pending: number } {
    let unspent = 0,
      spent = 0,
      pending = 0;
    for (const note of this.notes.values()) {
      if (note.status === "unspent") unspent++;
      else if (note.status === "spent") spent++;
      else pending++;
    }
    return { unspent, spent, pending };
  }

  private createDummyNote(ownerHash: Felt252, assetId: Felt252): PrivacyNote {
    const blinding = randomFelt252();
    const commitment = computeNoteCommitment({
      owner: ownerHash,
      value: 0n,
      assetId,
      blinding,
    });
    return {
      id: `dummy_${this.nextId++}`,
      owner: ownerHash,
      value: 0n,
      assetId,
      blinding,
      commitment,
      leafIndex: 0,
      status: "unspent",
      createdAt: Date.now(),
    };
  }
}
