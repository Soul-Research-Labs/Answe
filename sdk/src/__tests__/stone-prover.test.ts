import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  LocalProver,
  StoneProver,
  S2Prover,
  createProver,
} from "../stone-prover.js";
import type { WitnessPayload, ProverBackend } from "../stone-prover.js";

// ─── helpers ─────────────────────────────────────────────────────

function makeWitness(
  circuit: "transfer" | "withdraw" = "transfer",
): WitnessPayload {
  return {
    circuitType: circuit,
    publicInputs: [0xbeefn, 0x111n, 0x222n, 0xaaan, 0xbbbn],
    privateInputs: [0x999n, 100n, 200n],
  };
}

// ─── LocalProver ─────────────────────────────────────────────────

describe("LocalProver", () => {
  it("returns a successful ProofResult for transfer", async () => {
    const prover = new LocalProver();
    const result = await prover.prove(makeWitness("transfer"));
    expect(result.success).toBe(true);
    expect(result.proof).toBeDefined();
    expect(result.proof!.proofType).toBe(1);
    expect(result.proof!.merkleRoot).toBe(0xbeefn);
    expect(result.proof!.nullifiers).toEqual([0x111n, 0x222n]);
    expect(result.proof!.outputCommitments).toEqual([0xaaan, 0xbbbn]);
  });

  it("returns proofType 2 for withdraw", async () => {
    const prover = new LocalProver();
    const result = await prover.prove(makeWitness("withdraw"));
    expect(result.success).toBe(true);
    expect(result.proof!.proofType).toBe(2);
  });

  it("includes all inputs in proofData", async () => {
    const prover = new LocalProver();
    const w = makeWitness();
    const result = await prover.prove(w);
    expect(result.proof!.proofData).toEqual([
      ...w.publicInputs,
      ...w.privateInputs,
    ]);
  });

  it("healthCheck always returns true", async () => {
    const prover = new LocalProver();
    expect(await prover.healthCheck()).toBe(true);
  });

  it("name is local-mvp", () => {
    expect(new LocalProver().name).toBe("local-mvp");
  });
});

// ─── StoneProver ─────────────────────────────────────────────────

describe("StoneProver", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    fetchSpy = vi.spyOn(globalThis, "fetch");
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("name is stone-prover", () => {
    const p = new StoneProver({ endpoint: "http://localhost:3000" });
    expect(p.name).toBe("stone-prover");
  });

  it("submits witness and returns proof on 200", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          proof_data: ["0xaaa", "0xbbb"],
          prover_time_ms: 42,
        }),
        { status: 200 },
      ),
    );

    const prover = new StoneProver({
      endpoint: "http://stone:3000/",
      timeoutMs: 5000,
      maxRetries: 0,
    });
    const result = await prover.prove(makeWitness());

    expect(result.success).toBe(true);
    expect(result.proof!.proofData).toEqual([0xaaan, 0xbbbn]);
    expect(result.proof!.outputCommitments).toEqual([0xaaan, 0xbbbn]);
    expect(result.proof!.fee).toBe(0n);
    expect(fetchSpy).toHaveBeenCalledOnce();
  });

  it("returns validation error when proof_data is malformed", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          proof_data: ["0x1", "not-a-felt"],
          prover_time_ms: 12,
        }),
        { status: 200 },
      ),
    );

    const prover = new StoneProver({
      endpoint: "http://stone:3000",
      maxRetries: 0,
    });
    const result = await prover.prove(makeWitness());

    expect(result.success).toBe(false);
    expect(result.error).toContain("proof_data[1]");
  });

  it("returns error on 4xx", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response("bad request", { status: 400 }),
    );
    const prover = new StoneProver({
      endpoint: "http://stone:3000",
      maxRetries: 0,
    });
    const result = await prover.prove(makeWitness());
    expect(result.success).toBe(false);
    expect(result.error).toContain("400");
  });

  it("retries on 500 then succeeds", async () => {
    fetchSpy
      .mockResolvedValueOnce(new Response("error", { status: 500 }))
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({ proof_data: ["0x1"], prover_time_ms: 10 }),
          { status: 200 },
        ),
      );

    const prover = new StoneProver({
      endpoint: "http://stone:3000",
      maxRetries: 1,
      timeoutMs: 5000,
    });
    const result = await prover.prove(makeWitness());
    expect(result.success).toBe(true);
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it("returns error on network failure after retries", async () => {
    fetchSpy.mockRejectedValue(new Error("ECONNREFUSED"));
    const prover = new StoneProver({
      endpoint: "http://stone:3000",
      maxRetries: 1,
      timeoutMs: 1000,
    });
    const result = await prover.prove(makeWitness());
    expect(result.success).toBe(false);
    expect(result.error).toContain("ECONNREFUSED");
  });

  it("healthCheck returns true on 200", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("ok", { status: 200 }));
    const prover = new StoneProver({ endpoint: "http://stone:3000" });
    expect(await prover.healthCheck()).toBe(true);
  });

  it("healthCheck returns false on failure", async () => {
    fetchSpy.mockRejectedValueOnce(new Error("unreachable"));
    const prover = new StoneProver({ endpoint: "http://stone:3000" });
    expect(await prover.healthCheck()).toBe(false);
  });

  it("sends Authorization header when apiKey set", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ proof_data: [], prover_time_ms: 0 }), {
        status: 200,
      }),
    );
    const prover = new StoneProver({
      endpoint: "http://stone:3000",
      apiKey: "test-key",
      maxRetries: 0,
    });
    await prover.prove(makeWitness());

    const callArgs = fetchSpy.mock.calls[0];
    const init = callArgs[1] as RequestInit;
    expect((init.headers as Record<string, string>)["Authorization"]).toBe(
      "Bearer test-key",
    );
  });
});

// ─── S2Prover ────────────────────────────────────────────────────

describe("S2Prover", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    fetchSpy = vi.spyOn(globalThis, "fetch");
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("name is s-two", () => {
    const p = new S2Prover({ endpoint: "http://s2:3000" });
    expect(p.name).toBe("s-two");
  });

  it("submits job and polls until completed", async () => {
    // Submit returns job_id
    fetchSpy
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ job_id: "abc123" }), { status: 200 }),
      )
      // First poll: pending
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ status: "pending" }), { status: 200 }),
      )
      // Second poll: completed
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            status: "completed",
            proof_data: ["0xDEAD"],
            prover_time_ms: 50,
          }),
          { status: 200 },
        ),
      );

    const prover = new S2Prover({
      endpoint: "http://s2:3000",
      timeoutMs: 30_000,
      maxRetries: 0,
    });
    // Override poll interval for fast test
    (prover as any).pollIntervalMs = 10;

    const result = await prover.prove(makeWitness("withdraw"));
    expect(result.success).toBe(true);
    expect(result.proof!.proofType).toBe(2);
    expect(result.proof!.proofData).toEqual([0xdeadn]);
  });

  it("maps withdraw public inputs into proof envelope fields", async () => {
    const withdrawWitness: WitnessPayload = {
      circuitType: "withdraw",
      publicInputs: [0x111n, 0x222n, 0x333n, 0x444n, 50n, 9n, 3n],
      privateInputs: [0xaaaan],
    };

    fetchSpy
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ job_id: "w1" }), { status: 200 }),
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            status: "completed",
            proof_data: ["0x55"],
            prover_time_ms: 2,
          }),
          { status: 200 },
        ),
      );

    const prover = new S2Prover({ endpoint: "http://s2:3000", maxRetries: 0 });
    (prover as any).pollIntervalMs = 10;

    const result = await prover.prove(withdrawWitness);
    expect(result.success).toBe(true);
    expect(result.proof!.outputCommitments).toEqual([0x444n]);
    expect(result.proof!.exitValue).toBe(50n);
    expect(result.proof!.assetId).toBe(9n);
    expect(result.proof!.fee).toBe(3n);
  });

  it("returns error when job fails", async () => {
    fetchSpy
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ job_id: "fail1" }), { status: 200 }),
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ status: "failed", error: "OOM" }), {
          status: 200,
        }),
      );

    const prover = new S2Prover({
      endpoint: "http://s2:3000",
      maxRetries: 0,
    });
    (prover as any).pollIntervalMs = 10;

    const result = await prover.prove(makeWitness());
    expect(result.success).toBe(false);
    expect(result.error).toContain("OOM");
  });

  it("returns error on submit failure", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("forbidden", { status: 403 }));
    const prover = new S2Prover({
      endpoint: "http://s2:3000",
      maxRetries: 0,
    });
    const result = await prover.prove(makeWitness());
    expect(result.success).toBe(false);
    expect(result.error).toContain("403");
  });

  it("returns error when submit response has no job_id", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    );

    const prover = new S2Prover({
      endpoint: "http://s2:3000",
      maxRetries: 0,
    });

    const result = await prover.prove(makeWitness());
    expect(result.success).toBe(false);
    expect(result.error).toContain("missing job_id");
  });

  it("healthCheck returns true on 200", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("ok", { status: 200 }));
    const prover = new S2Prover({ endpoint: "http://s2:3000" });
    expect(await prover.healthCheck()).toBe(true);
  });

  it("sends X-API-Key header when apiKey set", async () => {
    fetchSpy
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ job_id: "x" }), { status: 200 }),
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            status: "completed",
            proof_data: ["0x1"],
            prover_time_ms: 1,
          }),
          { status: 200 },
        ),
      );
    const prover = new S2Prover({
      endpoint: "http://s2:3000",
      apiKey: "my-key",
      maxRetries: 0,
    });
    (prover as any).pollIntervalMs = 10;
    await prover.prove(makeWitness());

    const submitCall = fetchSpy.mock.calls[0];
    const init = submitCall[1] as RequestInit;
    expect((init.headers as Record<string, string>)["X-API-Key"]).toBe(
      "my-key",
    );
  });
});

// ─── createProver factory ────────────────────────────────────────

describe("createProver", () => {
  it("creates LocalProver for 'local'", () => {
    const p = createProver("local");
    expect(p.name).toBe("local-mvp");
  });

  it("creates StoneProver for 'stone'", () => {
    const p = createProver("stone", { endpoint: "http://x" });
    expect(p.name).toBe("stone-prover");
  });

  it("creates S2Prover for 's-two'", () => {
    const p = createProver("s-two", { endpoint: "http://x" });
    expect(p.name).toBe("s-two");
  });

  it("throws if remote config missing for stone", () => {
    expect(() => createProver("stone")).toThrow();
  });

  it("throws if remote config missing for s-two", () => {
    expect(() => createProver("s-two")).toThrow();
  });
});
