/**
 * Stone-prover / S-Two integration module.
 *
 * Provides a ProverBackend interface that abstracts STARK proof generation,
 * with three implementations:
 *   1. LocalProver  — in-process witness assembly (current MVP; no real STARK)
 *   2. StoneProver  — delegates to a remote stone-prover HTTP endpoint
 *   3. S2Prover     — delegates to a remote S-Two prover endpoint
 *
 * The prover backend can be passed to the StarkPrivacyClient to swap
 * proof generation strategies without changing caller code.
 */
import type { Felt252, ProofRequest, ProofResult } from "./types.js";

// ─── Types ───────────────────────────────────────────────────────

/** Circuit type for proof generation. */
export type CircuitType = "transfer" | "withdraw";

/** Serialised witness ready for the prover backend. */
export interface WitnessPayload {
  circuitType: CircuitType;
  /** Public inputs: Merkle root, nullifiers, output commitments, etc. */
  publicInputs: Felt252[];
  /** Private inputs: spending key, note values, Merkle paths, etc. */
  privateInputs: Felt252[];
}

/** Config shared by all remote prover backends. */
export interface RemoteProverConfig {
  /** Base URL of the prover service (e.g. "https://prover.example.com"). */
  endpoint: string;
  /** Optional API key for authenticated endpoints. */
  apiKey?: string;
  /** Request timeout in milliseconds (default 120 000). */
  timeoutMs?: number;
  /** Maximum retry attempts on transient errors (default 2). */
  maxRetries?: number;
}

/** The result returned by a prover backend before wrapping into ProofResult. */
export interface RawSTARKProof {
  /** The STARK proof elements (felts). */
  proofData: Felt252[];
  /** Prover execution time in milliseconds. */
  proverTimeMs: number;
}

// ─── Interface ───────────────────────────────────────────────────

/**
 * Abstract prover backend. Implementations handle witness serialisation
 * and proof generation (either locally or via a remote endpoint).
 */
export interface ProverBackend {
  /** Human-readable name (for logging). */
  readonly name: string;
  /** Generate a STARK proof from a witness payload. */
  prove(witness: WitnessPayload): Promise<ProofResult>;
  /** Check whether the prover service is reachable. */
  healthCheck(): Promise<boolean>;
}

// ─── Local (MVP) implementation ──────────────────────────────────

/**
 * In-process "prover" that just returns the witness as proof data
 * (no real STARK computation). Used for testing and development.
 */
export class LocalProver implements ProverBackend {
  readonly name = "local-mvp";

  async prove(witness: WitnessPayload): Promise<ProofResult> {
    const proofData = [...witness.publicInputs, ...witness.privateInputs];
    const proof: ProofRequest = {
      proofType: witness.circuitType === "transfer" ? 1 : 2,
      merkleRoot: witness.publicInputs[0] ?? 0n,
      nullifiers: [
        witness.publicInputs[1] ?? 0n,
        witness.publicInputs[2] ?? 0n,
      ],
      outputCommitments: witness.publicInputs.slice(3),
      fee: 0n,
      proofData,
    };
    return { success: true, proof };
  }

  async healthCheck(): Promise<boolean> {
    return true; // Always available
  }
}

// ─── Remote helpers ──────────────────────────────────────────────

function serializeWitness(witness: WitnessPayload): string {
  return JSON.stringify({
    circuit_type: witness.circuitType,
    public_inputs: witness.publicInputs.map((f) => "0x" + f.toString(16)),
    private_inputs: witness.privateInputs.map((f) => "0x" + f.toString(16)),
  });
}

function parseProofResponse(data: {
  proof_data: string[];
  prover_time_ms: number;
}): RawSTARKProof {
  return {
    proofData: data.proof_data.map((h) => BigInt(h)),
    proverTimeMs: data.prover_time_ms,
  };
}

async function fetchWithRetry(
  url: string,
  init: RequestInit,
  maxRetries: number,
  timeoutMs: number,
): Promise<Response> {
  let lastError: Error | undefined;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(url, { ...init, signal: controller.signal });
      clearTimeout(timer);
      if (res.ok || res.status < 500) return res;
      lastError = new Error(`HTTP ${res.status}`);
    } catch (err) {
      clearTimeout(timer);
      lastError = err instanceof Error ? err : new Error(String(err));
    }
    // Exponential back-off: 500ms, 1s, 2s …
    if (attempt < maxRetries) {
      await new Promise((r) => setTimeout(r, 500 * 2 ** attempt));
    }
  }
  throw lastError ?? new Error("fetch failed");
}

// ─── Stone Prover ────────────────────────────────────────────────

/**
 * Delegates proof generation to a remote stone-prover service.
 *
 * Expected endpoints:
 *   POST /prove     — submit a witness, receive a STARK proof
 *   GET  /health    — health check
 */
export class StoneProver implements ProverBackend {
  readonly name = "stone-prover";
  private config: Required<RemoteProverConfig>;

  constructor(config: RemoteProverConfig) {
    this.config = {
      endpoint: config.endpoint.replace(/\/+$/, ""),
      apiKey: config.apiKey ?? "",
      timeoutMs: config.timeoutMs ?? 120_000,
      maxRetries: config.maxRetries ?? 2,
    };
  }

  async prove(witness: WitnessPayload): Promise<ProofResult> {
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };
    if (this.config.apiKey) {
      headers["Authorization"] = `Bearer ${this.config.apiKey}`;
    }

    try {
      const res = await fetchWithRetry(
        `${this.config.endpoint}/prove`,
        { method: "POST", headers, body: serializeWitness(witness) },
        this.config.maxRetries,
        this.config.timeoutMs,
      );

      if (!res.ok) {
        const text = await res.text();
        return {
          success: false,
          error: `stone-prover error ${res.status}: ${text}`,
        };
      }

      const data = (await res.json()) as {
        proof_data: string[];
        prover_time_ms: number;
      };
      const raw = parseProofResponse(data);

      const proof: ProofRequest = {
        proofType: witness.circuitType === "transfer" ? 1 : 2,
        merkleRoot: witness.publicInputs[0] ?? 0n,
        nullifiers: [
          witness.publicInputs[1] ?? 0n,
          witness.publicInputs[2] ?? 0n,
        ],
        outputCommitments: witness.publicInputs.slice(3),
        fee: 0n,
        proofData: raw.proofData,
      };

      return { success: true, proof };
    } catch (err) {
      return {
        success: false,
        error: `stone-prover request failed: ${err instanceof Error ? err.message : String(err)}`,
      };
    }
  }

  async healthCheck(): Promise<boolean> {
    try {
      const res = await fetch(`${this.config.endpoint}/health`, {
        signal: AbortSignal.timeout(5000),
      });
      return res.ok;
    } catch {
      return false;
    }
  }
}

// ─── S-Two Prover ────────────────────────────────────────────────

/**
 * Delegates proof generation to a remote S-Two prover service.
 *
 * S-Two expects a slightly different API shape:
 *   POST /api/v1/proofs     — create proof job
 *   GET  /api/v1/proofs/:id — poll for result
 *   GET  /api/v1/status     — health check
 */
export class S2Prover implements ProverBackend {
  readonly name = "s-two";
  private config: Required<RemoteProverConfig>;
  private pollIntervalMs = 2_000;

  constructor(config: RemoteProverConfig) {
    this.config = {
      endpoint: config.endpoint.replace(/\/+$/, ""),
      apiKey: config.apiKey ?? "",
      timeoutMs: config.timeoutMs ?? 120_000,
      maxRetries: config.maxRetries ?? 2,
    };
  }

  async prove(witness: WitnessPayload): Promise<ProofResult> {
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };
    if (this.config.apiKey) {
      headers["X-API-Key"] = this.config.apiKey;
    }

    try {
      // 1. Submit job
      const submitRes = await fetchWithRetry(
        `${this.config.endpoint}/api/v1/proofs`,
        { method: "POST", headers, body: serializeWitness(witness) },
        this.config.maxRetries,
        this.config.timeoutMs,
      );

      if (!submitRes.ok) {
        const text = await submitRes.text();
        return {
          success: false,
          error: `s-two submit error ${submitRes.status}: ${text}`,
        };
      }

      const { job_id } = (await submitRes.json()) as { job_id: string };

      // 2. Poll for result
      const deadline = Date.now() + this.config.timeoutMs;
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, this.pollIntervalMs));
        const pollRes = await fetch(
          `${this.config.endpoint}/api/v1/proofs/${encodeURIComponent(job_id)}`,
          { headers, signal: AbortSignal.timeout(10_000) },
        );

        if (!pollRes.ok) continue;

        const body = (await pollRes.json()) as {
          status: string;
          proof_data?: string[];
          prover_time_ms?: number;
          error?: string;
        };

        if (body.status === "completed" && body.proof_data) {
          const raw = parseProofResponse({
            proof_data: body.proof_data,
            prover_time_ms: body.prover_time_ms ?? 0,
          });

          const proof: ProofRequest = {
            proofType: witness.circuitType === "transfer" ? 1 : 2,
            merkleRoot: witness.publicInputs[0] ?? 0n,
            nullifiers: [
              witness.publicInputs[1] ?? 0n,
              witness.publicInputs[2] ?? 0n,
            ],
            outputCommitments: witness.publicInputs.slice(3),
            fee: 0n,
            proofData: raw.proofData,
          };
          return { success: true, proof };
        }

        if (body.status === "failed") {
          return {
            success: false,
            error: `s-two proof failed: ${body.error ?? "unknown"}`,
          };
        }
        // "pending" / "processing" — keep polling
      }

      return { success: false, error: "s-two proof timed out" };
    } catch (err) {
      return {
        success: false,
        error: `s-two request failed: ${err instanceof Error ? err.message : String(err)}`,
      };
    }
  }

  async healthCheck(): Promise<boolean> {
    try {
      const res = await fetch(`${this.config.endpoint}/api/v1/status`, {
        signal: AbortSignal.timeout(5000),
      });
      return res.ok;
    } catch {
      return false;
    }
  }
}

// ─── Factory ─────────────────────────────────────────────────────

/** Create a prover backend by name. */
export function createProver(
  backend: "local" | "stone" | "s-two",
  config?: RemoteProverConfig,
): ProverBackend {
  switch (backend) {
    case "local":
      return new LocalProver();
    case "stone":
      if (!config)
        throw new Error("RemoteProverConfig required for stone backend");
      return new StoneProver(config);
    case "s-two":
      if (!config)
        throw new Error("RemoteProverConfig required for s-two backend");
      return new S2Prover(config);
  }
}
