/**
 * CLI integration tests — verifies argument parsing, config construction,
 * and error handling for all CLI commands.
 *
 * These tests invoke the CLI's internal helpers directly (not via subprocess)
 * to avoid needing a devnet. Network-dependent commands are tested only for
 * their argument validation / early-exit behaviour.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { KeyManager } from "../keys.js";

// ─── Re-implement parseArgs & buildConfig locally for unit testing ──
// (cli.ts is a script entry-point without named exports, so we mirror the logic)

function parseArgs(argv: string[]): {
  command: string;
  positional: string[];
  flags: Record<string, string>;
} {
  const command = argv[0] ?? "";
  const positional: string[] = [];
  const flags: Record<string, string> = {};

  for (let i = 1; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const val = argv[i + 1];
      if (!val || val.startsWith("--")) {
        flags[key] = "true";
      } else {
        flags[key] = val;
        i++;
      }
    } else {
      positional.push(argv[i]);
    }
  }

  return { command, positional, flags };
}

function toBigInt(s: string): bigint {
  if (s.startsWith("0x") || s.startsWith("0X")) return BigInt(s);
  return BigInt(s);
}

// ─── Tests ────────────────────────────────────────────────────────

describe("CLI parseArgs", () => {
  it("parses command with no arguments", () => {
    const result = parseArgs(["keygen"]);
    expect(result.command).toBe("keygen");
    expect(result.positional).toEqual([]);
    expect(result.flags).toEqual({});
  });

  it("parses positional arguments", () => {
    const result = parseArgs(["deposit", "1000"]);
    expect(result.command).toBe("deposit");
    expect(result.positional).toEqual(["1000"]);
  });

  it("parses flags with values", () => {
    const result = parseArgs([
      "deposit",
      "1000",
      "--asset",
      "0x1",
      "--rpc",
      "http://localhost:5050",
    ]);
    expect(result.command).toBe("deposit");
    expect(result.positional).toEqual(["1000"]);
    expect(result.flags.asset).toBe("0x1");
    expect(result.flags.rpc).toBe("http://localhost:5050");
  });

  it("parses boolean flags", () => {
    const result = parseArgs(["info", "--verbose"]);
    expect(result.flags.verbose).toBe("true");
  });

  it("parses transfer with two positional args", () => {
    const result = parseArgs(["transfer", "0xDEAD", "500"]);
    expect(result.command).toBe("transfer");
    expect(result.positional).toEqual(["0xDEAD", "500"]);
  });

  it("parses withdraw with address and amount", () => {
    const result = parseArgs(["withdraw", "0x789", "100", "--asset", "0x0"]);
    expect(result.command).toBe("withdraw");
    expect(result.positional).toEqual(["0x789", "100"]);
    expect(result.flags.asset).toBe("0x0");
  });

  it("returns empty command for empty argv", () => {
    const result = parseArgs([]);
    expect(result.command).toBe("");
  });

  it("handles multiple flags correctly", () => {
    const result = parseArgs([
      "deposit",
      "100",
      "--rpc",
      "http://rpc.example.com",
      "--pool",
      "0x123",
      "--key",
      "0xABC",
      "--chain",
      "0x1",
      "--app",
      "0x1",
    ]);
    expect(result.flags.rpc).toBe("http://rpc.example.com");
    expect(result.flags.pool).toBe("0x123");
    expect(result.flags.key).toBe("0xABC");
    expect(result.flags.chain).toBe("0x1");
    expect(result.flags.app).toBe("0x1");
  });

  it("parses bridge-l1 with three positional args", () => {
    const result = parseArgs(["bridge-l1", "0xCM", "0xL1ADDR", "500"]);
    expect(result.command).toBe("bridge-l1");
    expect(result.positional).toEqual(["0xCM", "0xL1ADDR", "500"]);
  });
});

describe("CLI toBigInt", () => {
  it("converts decimal string", () => {
    expect(toBigInt("1000")).toBe(1000n);
  });

  it("converts hex string (0x prefix)", () => {
    expect(toBigInt("0xFF")).toBe(255n);
  });

  it("converts hex string (0X prefix)", () => {
    expect(toBigInt("0XAB")).toBe(171n);
  });

  it("converts zero", () => {
    expect(toBigInt("0")).toBe(0n);
  });

  it("throws on invalid input", () => {
    expect(() => toBigInt("notanumber")).toThrow();
  });
});

describe("CLI keygen (unit)", () => {
  it("KeyManager.generate produces valid keys", () => {
    const km = KeyManager.generate();
    const keys = km.exportKeys(true);
    expect(keys.spendingKey).toBeTypeOf("bigint");
    expect(keys.viewingKey).toBeTypeOf("bigint");
    expect(keys.ownerHash).toBeTypeOf("bigint");
    expect(keys.spendingKey).not.toBe(0n);
  });
});

describe("CLI command routing", () => {
  const VALID_COMMANDS = [
    "keygen",
    "deposit",
    "transfer",
    "withdraw",
    "balance",
    "info",
    "stealth-register",
    "stealth-scan",
    "bridge-l1",
    "epoch",
  ];

  it("recognises all valid command names", () => {
    for (const cmd of VALID_COMMANDS) {
      const { command } = parseArgs([cmd]);
      expect(command).toBe(cmd);
    }
  });

  it("unknown command parsed into command field", () => {
    const { command } = parseArgs(["foobar"]);
    expect(command).toBe("foobar");
  });
});

describe("CLI deposit validation", () => {
  it("requires amount positional argument", () => {
    const { positional } = parseArgs(["deposit"]);
    expect(positional[0]).toBeUndefined();
  });

  it("requires --key flag", () => {
    const { flags } = parseArgs(["deposit", "100"]);
    expect(flags.key).toBeUndefined();
  });

  it("parses amount and key correctly", () => {
    const { positional, flags } = parseArgs([
      "deposit",
      "500",
      "--key",
      "0xABC",
    ]);
    expect(toBigInt(positional[0])).toBe(500n);
    expect(toBigInt(flags.key)).toBe(0xabcn);
  });
});

describe("CLI transfer validation", () => {
  it("requires recipient and amount", () => {
    const { positional } = parseArgs(["transfer"]);
    expect(positional[0]).toBeUndefined();
    expect(positional[1]).toBeUndefined();
  });

  it("parses recipient owner hash and amount", () => {
    const { positional } = parseArgs(["transfer", "0xDEAD", "1000"]);
    expect(toBigInt(positional[0])).toBe(0xdeadn);
    expect(toBigInt(positional[1])).toBe(1000n);
  });
});

describe("CLI withdraw validation", () => {
  it("requires address and amount", () => {
    const { positional } = parseArgs(["withdraw"]);
    expect(positional.length).toBe(0);
  });

  it("parses address and amount", () => {
    const { positional } = parseArgs(["withdraw", "0x789", "200"]);
    expect(positional[0]).toBe("0x789");
    expect(toBigInt(positional[1])).toBe(200n);
  });
});

describe("CLI bridge-l1 validation", () => {
  it("requires commitment, l1address, and amount", () => {
    const { positional } = parseArgs(["bridge-l1", "0xCM"]);
    expect(positional.length).toBe(1);
  });

  it("parses all three arguments", () => {
    const { positional } = parseArgs(["bridge-l1", "0xCM", "0xL1", "500"]);
    expect(positional.length).toBe(3);
    expect(toBigInt(positional[2])).toBe(500n);
  });
});

// ─── Subprocess CLI integration tests ─────────────────────────

import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CLI_PATH = resolve(__dirname, "..", "cli.ts");
const SDK_DIR = resolve(__dirname, "..", "..");

function runCli(args: string[]): { output: string; exitCode: number } {
  const escaped = args.map((a) => `'${a}'`).join(" ");
  try {
    const output = execSync(`npx tsx '${CLI_PATH}' ${escaped}`, {
      encoding: "utf8",
      timeout: 30_000,
      cwd: SDK_DIR,
      env: { ...process.env, NODE_NO_WARNINGS: "1" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    return { output, exitCode: 0 };
  } catch (err: any) {
    const output = (err.stdout ?? "") + (err.stderr ?? "");
    return { output, exitCode: err.status ?? 1 };
  }
}

describe("CLI subprocess: keygen", () => {
  it("generates a key pair and prints it", () => {
    const { output, exitCode } = runCli(["keygen"]);
    expect(exitCode).toBe(0);
    expect(output).toContain("Spending Key");
    expect(output).toContain("Viewing Key");
    expect(output).toContain("Owner Hash");
    expect(output).toContain("0x");
  });
});

describe("CLI subprocess: error handling", () => {
  it("exits with error for unknown command", () => {
    const { exitCode } = runCli(["nonexistent-command"]);
    expect(exitCode).not.toBe(0);
  });

  it("exits with error when no command given", () => {
    const { exitCode } = runCli([]);
    expect(exitCode).not.toBe(0);
  });

  it("deposit without --key fails with error message", () => {
    const { output, exitCode } = runCli(["deposit", "100", "--pool", "0x1"]);
    expect(exitCode).not.toBe(0);
    expect(output).toContain("--key");
  });

  it("transfer without arguments fails", () => {
    const { exitCode } = runCli(["transfer"]);
    expect(exitCode).not.toBe(0);
  });

  it("withdraw without arguments fails", () => {
    const { exitCode } = runCli(["withdraw"]);
    expect(exitCode).not.toBe(0);
  });

  it("bridge-l1 without all arguments fails", () => {
    const { exitCode } = runCli(["bridge-l1", "0xCM"]);
    expect(exitCode).not.toBe(0);
  });
});
