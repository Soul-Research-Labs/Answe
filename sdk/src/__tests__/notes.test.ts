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
});
