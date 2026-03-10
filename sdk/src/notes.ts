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
import {
  createHash,
  randomBytes,
  createCipheriv,
  createDecipheriv,
  pbkdf2Sync,
} from "crypto";

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

  // ─── Encrypted Persistence ──────────────────────────────────

  /**
   * Export all notes as an encrypted JSON blob.
   * Uses AES-256-GCM with a password-derived key (PBKDF2, 100k iterations).
   *
   * @param password - Encryption password (user-supplied).
   * @returns Base64-encoded encrypted blob (salt:iv:tag:ciphertext).
   */
  exportEncrypted(password: string): string {
    const notes = this.exportNotes();
    const serialized: SerializedNote[] = notes.map((n) => ({
      id: n.id,
      owner: n.owner.toString(16),
      value: n.value.toString(),
      assetId: n.assetId.toString(16),
      blinding: n.blinding.toString(16),
      commitment: n.commitment.toString(16),
      leafIndex: n.leafIndex,
      status: n.status,
      createdAt: n.createdAt,
    }));

    const plaintext = JSON.stringify({
      version: 1,
      nextId: this.nextId,
      notes: serialized,
    });
    const salt = randomBytes(32);
    const key = pbkdf2Sync(password, salt, 100_000, 32, "sha256");
    const iv = randomBytes(12);

    const cipher = createCipheriv("aes-256-gcm", key, iv);
    const encrypted = Buffer.concat([
      cipher.update(plaintext, "utf8"),
      cipher.final(),
    ]);
    const tag = cipher.getAuthTag();

    // Format: salt(32) || iv(12) || tag(16) || ciphertext
    return Buffer.concat([salt, iv, tag, encrypted]).toString("base64");
  }

  /**
   * Import notes from an encrypted blob produced by `exportEncrypted`.
   *
   * @param blob - Base64-encoded encrypted blob.
   * @param password - Decryption password.
   * @param merge - If true, add to existing notes; if false, replace all.
   */
  importEncrypted(blob: string, password: string, merge = false): void {
    const data = Buffer.from(blob, "base64");
    if (data.length < 60) throw new Error("Invalid encrypted blob");

    const salt = data.subarray(0, 32);
    const iv = data.subarray(32, 44);
    const tag = data.subarray(44, 60);
    const ciphertext = data.subarray(60);

    const key = pbkdf2Sync(password, salt, 100_000, 32, "sha256");
    const decipher = createDecipheriv("aes-256-gcm", key, iv);
    decipher.setAuthTag(tag);

    let plaintext: string;
    try {
      plaintext =
        decipher.update(ciphertext).toString("utf8") + decipher.final("utf8");
    } catch {
      throw new Error("Decryption failed — wrong password or corrupted data");
    }

    const parsed = JSON.parse(plaintext) as {
      version: number;
      nextId: number;
      notes: SerializedNote[];
    };
    if (parsed.version !== 1)
      throw new Error(`Unsupported blob version: ${parsed.version}`);

    if (!merge) {
      this.notes.clear();
    }

    for (const s of parsed.notes) {
      const note: PrivacyNote = {
        id: s.id,
        owner: BigInt("0x" + s.owner),
        value: BigInt(s.value),
        assetId: BigInt("0x" + s.assetId),
        blinding: BigInt("0x" + s.blinding),
        commitment: BigInt("0x" + s.commitment),
        leafIndex: s.leafIndex,
        status: s.status,
        createdAt: s.createdAt,
      };

      // In merge mode, skip notes that conflict with existing IDs
      if (merge && this.notes.has(note.id)) {
        continue;
      }
      this.notes.set(note.id, note);
    }

    this.nextId = Math.max(this.nextId, parsed.nextId);
  }
}

/** Serialized note format for encrypted storage. */
interface SerializedNote {
  id: string;
  owner: string;
  value: string;
  assetId: string;
  blinding: string;
  commitment: string;
  leafIndex?: number;
  status: NoteStatus;
  createdAt: number;
}
