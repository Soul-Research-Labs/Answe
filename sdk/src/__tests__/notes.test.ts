import { describe, it, expect } from "vitest";
import { NoteManager } from "../notes.js";
import { computeNoteCommitment, computeNullifier } from "../crypto.js";

describe("NoteManager", () => {
  describe("createNote", () => {
    it("creates a note with correct fields", () => {
      const nm = new NoteManager();
      const owner = 100n;
      const note = nm.createNote(owner, 1000n, 0n);

      expect(note.owner).toBe(owner);
      expect(note.value).toBe(1000n);
      expect(note.assetId).toBe(0n);
      expect(note.status).toBe("unspent");
      expect(typeof note.blinding).toBe("bigint");
      expect(typeof note.commitment).toBe("bigint");
      expect(note.id).toMatch(/^note_/);
    });

    it("commitment matches manual computation", () => {
      const nm = new NoteManager();
      const note = nm.createNote(100n, 1000n, 0n);
      const expected = computeNoteCommitment({
        owner: note.owner,
        value: note.value,
        assetId: note.assetId,
        blinding: note.blinding,
      });
      expect(note.commitment).toBe(expected);
    });

    it("each note gets a unique id", () => {
      const nm = new NoteManager();
      const n1 = nm.createNote(1n, 100n);
      const n2 = nm.createNote(1n, 200n);
      expect(n1.id).not.toBe(n2.id);
    });
  });

  describe("importNote", () => {
    it("imports with given blinding", () => {
      const nm = new NoteManager();
      const note = nm.importNote({
        owner: 10n,
        value: 500n,
        assetId: 0n,
        blinding: 42n,
        leafIndex: 5,
      });
      expect(note.blinding).toBe(42n);
      expect(note.leafIndex).toBe(5);
      expect(note.status).toBe("unspent");
    });
  });

  describe("markSpent", () => {
    it("marks notes as spent", () => {
      const nm = new NoteManager();
      const n1 = nm.createNote(1n, 100n);
      nm.markSpent([n1.id]);
      const stats = nm.getStats();
      expect(stats.spent).toBe(1);
      expect(stats.unspent).toBe(0);
    });

    it("throws on unknown note", () => {
      const nm = new NoteManager();
      expect(() => nm.markSpent(["nonexistent"])).toThrow("not found");
    });
  });

  describe("getBalance", () => {
    it("sums unspent notes", () => {
      const nm = new NoteManager();
      nm.createNote(1n, 100n, 0n);
      nm.createNote(1n, 200n, 0n);
      nm.createNote(1n, 50n, 1n); // different asset
      expect(nm.getBalance(0n)).toBe(300n);
      expect(nm.getBalance(1n)).toBe(50n);
    });

    it("excludes spent notes", () => {
      const nm = new NoteManager();
      const n1 = nm.createNote(1n, 100n, 0n);
      nm.createNote(1n, 200n, 0n);
      nm.markSpent([n1.id]);
      expect(nm.getBalance(0n)).toBe(200n);
    });
  });

  describe("selectNotes", () => {
    it("selects single note + dummy when sufficient", () => {
      const nm = new NoteManager();
      const n1 = nm.createNote(1n, 500n, 0n);
      nm.confirmNote(n1.id, 0); // must be confirmed

      const selected = nm.selectNotes(300n, 0n, 1n);
      expect(selected).toHaveLength(2);
      // One should have value 500, other is dummy (0)
      const values = [selected[0].value, selected[1].value].sort((a, b) =>
        a > b ? -1 : 1,
      );
      expect(values[0]).toBe(500n);
      expect(values[1]).toBe(0n);
    });

    it("selects two notes when neither alone is sufficient", () => {
      const nm = new NoteManager();
      const n1 = nm.createNote(1n, 300n, 0n);
      const n2 = nm.createNote(1n, 400n, 0n);
      nm.confirmNote(n1.id, 0);
      nm.confirmNote(n2.id, 1);

      const selected = nm.selectNotes(600n, 0n, 1n);
      expect(selected[0].value + selected[1].value).toBeGreaterThanOrEqual(
        600n,
      );
    });

    it("throws when balance insufficient", () => {
      const nm = new NoteManager();
      const n1 = nm.createNote(1n, 100n, 0n);
      nm.confirmNote(n1.id, 0);
      expect(() => nm.selectNotes(9999n, 0n, 1n)).toThrow("Insufficient");
    });

    it("ignores unconfirmed notes", () => {
      const nm = new NoteManager();
      nm.createNote(1n, 1000n, 0n); // no confirmNote
      expect(() => nm.selectNotes(100n, 0n, 1n)).toThrow();
    });
  });

  describe("computeNullifiers", () => {
    it("produces correct nullifiers", () => {
      const nm = new NoteManager();
      const n1 = nm.createNote(1n, 100n, 0n);
      const n2 = nm.createNote(1n, 200n, 0n);
      const sk = 42n;
      const chainId = 1n;
      const appId = 2n;

      const [nf1, nf2] = nm.computeNullifiers(sk, [n1, n2], chainId, appId);
      expect(nf1).toBe(computeNullifier(sk, n1.commitment, chainId, appId));
      expect(nf2).toBe(computeNullifier(sk, n2.commitment, chainId, appId));
    });
  });

  describe("getStats", () => {
    it("counts notes by status", () => {
      const nm = new NoteManager();
      nm.createNote(1n, 100n);
      nm.createNote(1n, 200n);
      const n3 = nm.createNote(1n, 300n);
      nm.markSpent([n3.id]);

      const stats = nm.getStats();
      expect(stats.unspent).toBe(2);
      expect(stats.spent).toBe(1);
      expect(stats.pending).toBe(0);
    });
  });

  describe("encrypted persistence", () => {
    it("round-trips notes through encrypt/decrypt", () => {
      const nm = new NoteManager();
      const n1 = nm.createNote(0xabcn, 1000n, 0n);
      nm.confirmNote(n1.id, 0);
      const n2 = nm.createNote(0xdefn, 2000n, 1n);
      nm.confirmNote(n2.id, 1);
      nm.markSpent([n1.id]);

      const blob = nm.exportEncrypted("test-password-123");
      expect(typeof blob).toBe("string");
      expect(blob.length).toBeGreaterThan(0);

      // Import into a fresh manager
      const nm2 = new NoteManager();
      nm2.importEncrypted(blob, "test-password-123");

      const notes = nm2.exportNotes();
      expect(notes.length).toBe(2);

      const restored1 = notes.find((n) => n.id === n1.id)!;
      expect(restored1.owner).toBe(0xabcn);
      expect(restored1.value).toBe(1000n);
      expect(restored1.status).toBe("spent");
      expect(restored1.leafIndex).toBe(0);

      const restored2 = notes.find((n) => n.id === n2.id)!;
      expect(restored2.owner).toBe(0xdefn);
      expect(restored2.value).toBe(2000n);
      expect(restored2.assetId).toBe(1n);
      expect(restored2.status).toBe("unspent");
    });

    it("wrong password throws", () => {
      const nm = new NoteManager();
      nm.createNote(1n, 100n);
      const blob = nm.exportEncrypted("correct-password");

      const nm2 = new NoteManager();
      expect(() => nm2.importEncrypted(blob, "wrong-password")).toThrow(
        /Decryption failed/,
      );
    });

    it("merge mode preserves existing notes", () => {
      const nm1 = new NoteManager();
      const imported = nm1.createNote(1n, 100n);
      const blob = nm1.exportEncrypted("pass");

      // Create second manager with a couple notes first
      // so its internal IDs don't collide with nm1
      const nm2 = new NoteManager();
      nm2.createNote(2n, 200n); // note_0
      nm2.createNote(2n, 300n); // note_1
      // merge should add the imported note (note_0 from nm1) — but since
      // note_0 already exists in nm2, it's skipped to avoid overwrite
      nm2.importEncrypted(blob, "pass", true);

      const allNotes = nm2.exportNotes();
      // The existing note_0 (200n) is preserved, imported note_0 is skipped
      expect(allNotes.length).toBe(2);
      expect(allNotes.find((n) => n.value === 200n)).toBeDefined();
    });

    it("replace mode clears existing notes", () => {
      const nm1 = new NoteManager();
      nm1.createNote(1n, 100n);
      const blob = nm1.exportEncrypted("pass");

      const nm2 = new NoteManager();
      nm2.createNote(2n, 200n);
      nm2.createNote(3n, 300n);
      nm2.importEncrypted(blob, "pass", false); // replace

      expect(nm2.exportNotes().length).toBe(1);
    });

    it("rejects truncated blob", () => {
      expect(() => new NoteManager().importEncrypted("AAAA", "pass")).toThrow(
        /Invalid encrypted blob/,
      );
    });
  });
});
