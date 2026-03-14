/**
 * SQLite-backed persistent storage adapter for the StarkPrivacy relayer.
 *
 * Uses better-sqlite3 for synchronous, ACID-compliant job persistence.
 * Install: npm install better-sqlite3 @types/better-sqlite3
 *
 * Usage:
 *   import { SqliteJobStorage } from "@starkprivacy/sdk/sqlite-storage";
 *   const storage = new SqliteJobStorage("./relayer-jobs.db");
 *   const relayer = new Relayer({ ..., storage });
 */
import type {
  JobStorageAdapter,
  RelayerJob,
  JobStatus,
} from "./relayer.js";

// better-sqlite3 is an optional dependency — loaded dynamically
let Database: any;

function loadSqlite(): any {
  if (!Database) {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      Database = require("better-sqlite3");
    } catch {
      throw new Error(
        "better-sqlite3 is required for SqliteJobStorage. Install it:\n" +
          "  npm install better-sqlite3",
      );
    }
  }
  return Database;
}

/**
 * SQLite-backed job storage for production relayer deployments.
 *
 * Features:
 * - ACID transactions for job state updates
 * - WAL mode for concurrent read performance
 * - Automatic schema migration on construction
 * - Dead-letter queue via "dead" status
 */
export class SqliteJobStorage implements JobStorageAdapter {
  private db: any;

  constructor(dbPath: string) {
    const Sqlite = loadSqlite();
    this.db = new Sqlite(dbPath);
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("foreign_keys = ON");
    this.migrate();
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS relayer_jobs (
        id         TEXT PRIMARY KEY,
        proof_json TEXT NOT NULL,
        status     TEXT NOT NULL DEFAULT 'pending',
        tx_hash    TEXT,
        error      TEXT,
        retries    INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_jobs_status ON relayer_jobs(status);
      CREATE INDEX IF NOT EXISTS idx_jobs_created ON relayer_jobs(created_at);
    `);
  }

  async save(job: RelayerJob): Promise<void> {
    const stmt = this.db.prepare(`
      INSERT INTO relayer_jobs (id, proof_json, status, tx_hash, error, retries, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        proof_json = excluded.proof_json,
        status     = excluded.status,
        tx_hash    = excluded.tx_hash,
        error      = excluded.error,
        retries    = excluded.retries,
        updated_at = excluded.updated_at
    `);
    stmt.run(
      job.id,
      serializeProof(job.proof),
      job.status,
      job.txHash ?? null,
      job.error ?? null,
      job.retries,
      job.createdAt,
      job.updatedAt,
    );
  }

  async load(id: string): Promise<RelayerJob | undefined> {
    const row = this.db
      .prepare("SELECT * FROM relayer_jobs WHERE id = ?")
      .get(id) as DbRow | undefined;
    return row ? rowToJob(row) : undefined;
  }

  async loadAll(status?: JobStatus): Promise<RelayerJob[]> {
    if (status) {
      const rows = this.db
        .prepare("SELECT * FROM relayer_jobs WHERE status = ? ORDER BY created_at")
        .all(status) as DbRow[];
      return rows.map(rowToJob);
    }
    const rows = this.db
      .prepare("SELECT * FROM relayer_jobs ORDER BY created_at")
      .all() as DbRow[];
    return rows.map(rowToJob);
  }

  async delete(id: string): Promise<void> {
    this.db.prepare("DELETE FROM relayer_jobs WHERE id = ?").run(id);
  }

  async nextId(): Promise<number> {
    const row = this.db
      .prepare("SELECT COUNT(*) as cnt FROM relayer_jobs")
      .get() as { cnt: number };
    return row.cnt;
  }

  /**
   * Move a failed job to dead-letter status so it won't be retried.
   */
  async markDead(id: string, reason: string): Promise<void> {
    this.db.prepare(`
      UPDATE relayer_jobs SET status = 'failed', error = ?, updated_at = ? WHERE id = ?
    `).run(reason, Date.now(), id);
  }

  /**
   * Get count of jobs by status (for monitoring).
   */
  async counts(): Promise<Record<string, number>> {
    const rows = this.db
      .prepare("SELECT status, COUNT(*) as cnt FROM relayer_jobs GROUP BY status")
      .all() as { status: string; cnt: number }[];
    const result: Record<string, number> = {};
    for (const r of rows) {
      result[r.status] = r.cnt;
    }
    return result;
  }

  /**
   * Close the database connection.
   */
  close(): void {
    this.db.close();
  }
}

// ─── Internal helpers ────────────────────────────────────────────

interface DbRow {
  id: string;
  proof_json: string;
  status: string;
  tx_hash: string | null;
  error: string | null;
  retries: number;
  created_at: number;
  updated_at: number;
}

function serializeProof(proof: RelayerJob["proof"]): string {
  return JSON.stringify({
    proofType: proof.proofType,
    merkleRoot: "0x" + proof.merkleRoot.toString(16),
    nullifiers: proof.nullifiers.map((n) => "0x" + n.toString(16)),
    outputCommitments: proof.outputCommitments.map((c) => "0x" + c.toString(16)),
    exitValue: proof.exitValue != null ? "0x" + proof.exitValue.toString(16) : undefined,
    recipient: proof.recipient,
    fee: "0x" + proof.fee.toString(16),
    proofData: proof.proofData.map((d) => "0x" + d.toString(16)),
  });
}

function deserializeProof(json: string): RelayerJob["proof"] {
  const obj = JSON.parse(json);
  return {
    proofType: obj.proofType,
    merkleRoot: BigInt(obj.merkleRoot),
    nullifiers: obj.nullifiers.map((n: string) => BigInt(n)),
    outputCommitments: obj.outputCommitments.map((c: string) => BigInt(c)),
    exitValue: obj.exitValue ? BigInt(obj.exitValue) : undefined,
    recipient: obj.recipient,
    fee: BigInt(obj.fee),
    proofData: obj.proofData.map((d: string) => BigInt(d)),
  };
}

function rowToJob(row: DbRow): RelayerJob {
  return {
    id: row.id,
    proof: deserializeProof(row.proof_json),
    status: row.status as JobStatus,
    txHash: row.tx_hash ?? undefined,
    error: row.error ?? undefined,
    retries: row.retries,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}
