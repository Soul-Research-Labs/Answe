#!/usr/bin/env node
/**
 * starkprivacy CLI — command-line interface for the StarkPrivacy protocol.
 *
 * Usage:
 *   starkprivacy keygen                        Generate a new key pair
 *   starkprivacy deposit <amount> [--asset 0]  Deposit tokens into the pool
 *   starkprivacy transfer <recipient> <amount> Private transfer
 *   starkprivacy withdraw <address> <amount>   Withdraw to public address
 *   starkprivacy balance [--asset 0]           Show shielded balance
 *   starkprivacy info                          Show pool contract info
 */

import { KeyManager } from "./keys.js";
import { StarkPrivacyClient, type StarkPrivacyConfig } from "./client.js";
import {
  NoteManager,
  saveNotesToFile,
  loadNotesFromFile,
  verifyBackup,
} from "./notes.js";
import type { Felt252 } from "./types.js";

// ─── Helpers ─────────────────────────────────────────────────────

function usage(): never {
  console.log(`
starkprivacy — Privacy-preserving transactions on Starknet

Commands:
  keygen                            Generate a new spending key
  deposit  <amount> [--asset <id>]  Deposit tokens into the privacy pool
  transfer <owner> <amount>         Send a private transfer
  withdraw <address> <amount>       Withdraw tokens to a public address
  balance  [--asset <id>]           Show shielded balance
  info                              Show pool contract info
  stealth-register                  Register stealth meta-address
  stealth-scan                      Scan for incoming stealth payments
  bridge-l1 <commitment> <l1addr> <amount>  Bridge to L1
  epoch                             Show current epoch info
  backup <file> --password <pw>     Encrypt and save notes to file
  restore <file> --password <pw>    Restore notes from encrypted backup
  verify-backup <file> --password <pw>  Verify a backup file
  verify-deployment                      Verify deployed contract health

Options:
  --rpc <url>        Starknet RPC endpoint (default: http://localhost:5050)
  --pool <address>   PrivacyPool contract address
  --stealth <addr>   StealthRegistry contract address
  --l1bridge <addr>  L1BridgeAdapter contract address
  --epochs <addr>    EpochManager contract address
  --key <hex>        Spending key (hex)
  --account <addr>   Starknet account address
  --privkey <hex>    Starknet account private key
  --chain <id>       Chain ID (default: 0x1)
  --app <id>         App ID (default: 0x1)
  --asset <id>       Asset ID (default: 0x0)
`);
  process.exit(1);
}

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

function buildConfig(flags: Record<string, string>): StarkPrivacyConfig {
  const config: StarkPrivacyConfig = {
    rpcUrl: flags.rpc ?? "http://localhost:5050",
    contracts: {
      pool: flags.pool ?? "0x0",
      nullifierRegistry: "0x0",
      stealthRegistry: flags.stealth ?? undefined,
      l1Bridge: flags.l1bridge ?? undefined,
      epochManager: flags.epochs ?? undefined,
      bridgeRouter: "0x0",
    },
    chainId: toBigInt(flags.chain ?? "0x1"),
    appId: toBigInt(flags.app ?? "0x1"),
  };

  if (flags.account && flags.privkey) {
    config.account = {
      address: flags.account,
      privateKey: flags.privkey,
    };
  }

  return config;
}

// ─── Commands ────────────────────────────────────────────────────

async function cmdKeygen(): Promise<void> {
  const km = KeyManager.generate();
  const keys = km.exportKeys(true);
  console.log("=== New StarkPrivacy Key Pair ===");
  console.log(`Spending Key : 0x${keys.spendingKey.toString(16)}`);
  console.log(`Viewing Key  : 0x${keys.viewingKey.toString(16)}`);
  console.log(`Owner Hash   : 0x${keys.ownerHash.toString(16)}`);
  console.log("\nSave the Spending Key securely — it controls your funds.");
}

async function cmdDeposit(
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  if (!positional[0]) {
    console.error("Error: deposit requires <amount>");
    process.exit(1);
  }

  const amount = toBigInt(positional[0]);
  const assetId = toBigInt(flags.asset ?? "0x0");
  const config = buildConfig(flags);

  if (!flags.key) {
    console.error("Error: --key <spending_key> is required");
    process.exit(1);
  }

  const client = StarkPrivacyClient.fromSpendingKey(
    config,
    toBigInt(flags.key),
  );
  console.log(`Depositing ${amount} (asset ${assetId}) into privacy pool...`);

  const { note, txHash } = await client.deposit(amount, assetId);
  console.log(`Deposit submitted!`);
  console.log(`  TX Hash    : ${txHash}`);
  console.log(`  Commitment : 0x${note.commitment.toString(16)}`);
  console.log(`  Note ID    : ${note.id}`);
}

async function cmdTransfer(
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  if (!positional[0] || !positional[1]) {
    console.error("Error: transfer requires <recipient_owner_hash> <amount>");
    process.exit(1);
  }

  const recipientOwner = toBigInt(positional[0]);
  const amount = toBigInt(positional[1]);
  const assetId = toBigInt(flags.asset ?? "0x0");
  const config = buildConfig(flags);

  if (!flags.key) {
    console.error("Error: --key <spending_key> is required");
    process.exit(1);
  }

  const client = StarkPrivacyClient.fromSpendingKey(
    config,
    toBigInt(flags.key),
  );
  console.log(`Transferring ${amount} to 0x${recipientOwner.toString(16)}...`);

  const { outputNotes, txHash } = await client.transfer(
    recipientOwner,
    amount,
    assetId,
  );
  console.log(`Transfer submitted!`);
  console.log(`  TX Hash          : ${txHash}`);
  console.log(
    `  Recipient Note   : 0x${outputNotes[0].commitment.toString(16)}`,
  );
  console.log(
    `  Change Note      : 0x${outputNotes[1].commitment.toString(16)}`,
  );
}

async function cmdWithdraw(
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  if (!positional[0] || !positional[1]) {
    console.error("Error: withdraw requires <address> <amount>");
    process.exit(1);
  }

  const recipient = positional[0];
  const amount = toBigInt(positional[1]);
  const assetId = toBigInt(flags.asset ?? "0x0");
  const config = buildConfig(flags);

  if (!flags.key) {
    console.error("Error: --key <spending_key> is required");
    process.exit(1);
  }

  const client = StarkPrivacyClient.fromSpendingKey(
    config,
    toBigInt(flags.key),
  );
  console.log(`Withdrawing ${amount} to ${recipient}...`);

  const { changeNote, txHash } = await client.withdraw(
    recipient,
    amount,
    assetId,
  );
  console.log(`Withdrawal submitted!`);
  console.log(`  TX Hash     : ${txHash}`);
  if (changeNote) {
    console.log(`  Change Note : 0x${changeNote.commitment.toString(16)}`);
  }
}

async function cmdBalance(flags: Record<string, string>): Promise<void> {
  const assetId = toBigInt(flags.asset ?? "0x0");

  if (!flags.key) {
    console.error("Error: --key <spending_key> is required");
    process.exit(1);
  }

  const config = buildConfig(flags);
  const client = StarkPrivacyClient.fromSpendingKey(
    config,
    toBigInt(flags.key),
  );
  const balance = client.getBalance(assetId);
  console.log(`Shielded Balance (asset ${assetId}): ${balance}`);
}

async function cmdInfo(flags: Record<string, string>): Promise<void> {
  const config = buildConfig(flags);
  const client = StarkPrivacyClient.fromSpendingKey(config, 1n);

  try {
    const root = await client.getRoot();
    const leafCount = await client.getLeafCount();
    console.log("=== Privacy Pool Info ===");
    console.log(`  Pool Address : ${config.contracts.pool}`);
    console.log(`  Merkle Root  : 0x${root.toString(16)}`);
    console.log(`  Leaf Count   : ${leafCount}`);
  } catch (e: any) {
    console.error(`Error querying pool: ${e.message}`);
    process.exit(1);
  }
}

// ─── Stealth & Bridge Commands ───────────────────────────────────

async function cmdStealthRegister(
  flags: Record<string, string>,
): Promise<void> {
  if (!flags.key) {
    console.error("Error: --key <spending_key> is required");
    process.exit(1);
  }

  const config = buildConfig(flags);
  const client = StarkPrivacyClient.fromSpendingKey(
    config,
    toBigInt(flags.key),
  );
  const keys = client.keys.exportKeys(true);

  console.log("Registering stealth meta-address...");
  console.log(`  Spending Pub : 0x${keys.spendingKey.toString(16)}`);
  console.log(`  Viewing Pub  : 0x${keys.viewingKey.toString(16)}`);

  const txHash = await client.registerStealthMetaAddress(
    keys.spendingKey,
    keys.viewingKey,
  );
  console.log(`  TX Hash      : ${txHash}`);
}

async function cmdStealthScan(flags: Record<string, string>): Promise<void> {
  if (!flags.key) {
    console.error("Error: --key <spending_key> is required");
    process.exit(1);
  }

  const config = buildConfig(flags);
  const client = StarkPrivacyClient.fromSpendingKey(
    config,
    toBigInt(flags.key),
  );
  const keys = client.keys.exportKeys(true);

  console.log("Scanning for stealth payments...");
  const found = await client.scanStealthNotes(keys.spendingKey);
  if (found.length === 0) {
    console.log("No stealth payments found.");
  } else {
    console.log(`Found ${found.length} stealth payment(s):`);
    for (const f of found) {
      console.log(`  [${f.index}] Commitment: 0x${f.commitment.toString(16)}`);
    }
  }
}

async function cmdBridgeL1(
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  if (!positional[0] || !positional[1] || !positional[2]) {
    console.error(
      "Error: bridge-l1 requires <commitment> <l1_address> <amount>",
    );
    process.exit(1);
  }

  const commitment = toBigInt(positional[0]);
  const l1Recipient = toBigInt(positional[1]);
  const amount = toBigInt(positional[2]);
  const assetId = toBigInt(flags.asset ?? "0x0");
  const config = buildConfig(flags);

  if (!flags.key) {
    console.error("Error: --key <spending_key> is required");
    process.exit(1);
  }

  const client = StarkPrivacyClient.fromSpendingKey(
    config,
    toBigInt(flags.key),
  );
  console.log(`Bridging to L1: ${amount} to 0x${l1Recipient.toString(16)}...`);

  const { txHash, messageHash } = await client.bridgeToL1(
    commitment,
    l1Recipient,
    amount,
    assetId,
  );
  console.log(`  TX Hash : ${txHash}`);
  if (messageHash) {
    console.log(`  L1 Msg  : ${messageHash}`);
  }
}

async function cmdEpoch(flags: Record<string, string>): Promise<void> {
  const config = buildConfig(flags);
  const client = StarkPrivacyClient.fromSpendingKey(config, 1n);

  try {
    const epoch = await client.getCurrentEpoch();
    console.log("=== Epoch Info ===");
    console.log(`  Current Epoch : ${epoch}`);
    if (epoch > 1n) {
      const prevRoot = await client.getEpochRoot(epoch - 1n);
      console.log(`  Prev Root     : 0x${prevRoot.toString(16)}`);
    }
  } catch (e: any) {
    console.error(`Error querying epoch: ${e.message}`);
    process.exit(1);
  }
}

// ─── Backup & Recovery Commands ──────────────────────────────────

async function cmdBackup(
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  if (!positional[0]) {
    console.error("Error: backup requires <file>");
    process.exit(1);
  }
  if (!flags.password) {
    console.error("Error: --password <pw> is required");
    process.exit(1);
  }
  if (!flags.key) {
    console.error("Error: --key <spending_key> is required");
    process.exit(1);
  }

  const config = buildConfig(flags);
  const client = StarkPrivacyClient.fromSpendingKey(
    config,
    toBigInt(flags.key),
  );
  const filePath = positional[0];

  console.log(`Saving encrypted note backup to ${filePath}...`);
  await saveNotesToFile(client.notes, filePath, flags.password);
  const stats = client.notes.getStats();
  const total = stats.unspent + stats.spent + stats.pending;
  console.log(`Backup complete: ${total} note(s) saved.`);
}

async function cmdRestore(
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  if (!positional[0]) {
    console.error("Error: restore requires <file>");
    process.exit(1);
  }
  if (!flags.password) {
    console.error("Error: --password <pw> is required");
    process.exit(1);
  }

  const filePath = positional[0];
  console.log(`Restoring notes from ${filePath}...`);

  const nm = await loadNotesFromFile(filePath, flags.password);
  const stats = nm.getStats();
  const total = stats.unspent + stats.spent + stats.pending;
  console.log(`Restore complete!`);
  console.log(`  Total notes : ${total}`);
  console.log(`  Unspent     : ${stats.unspent}`);
  console.log(`  Spent       : ${stats.spent}`);
  console.log(`  Pending     : ${stats.pending}`);
}

async function cmdVerifyBackup(
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  if (!positional[0]) {
    console.error("Error: verify-backup requires <file>");
    process.exit(1);
  }
  if (!flags.password) {
    console.error("Error: --password <pw> is required");
    process.exit(1);
  }

  const filePath = positional[0];
  console.log(`Verifying backup at ${filePath}...`);

  const stats = await verifyBackup(filePath, flags.password);
  console.log(`Backup is valid!`);
  console.log(`  Total notes : ${stats.noteCount}`);
  console.log(`  Unspent     : ${stats.unspent}`);
  console.log(`  Spent       : ${stats.spent}`);
  console.log(`  Pending     : ${stats.pending}`);
}

// ─── Verify Deployment ───────────────────────────────────────────

async function cmdVerifyDeployment(flags: Record<string, string>): Promise<void> {
  const rpc = flags.rpc || "http://localhost:5050";
  const poolAddr = flags.pool;

  if (!poolAddr) {
    console.error("Error: --pool <address> is required");
    process.exit(1);
  }

  const { RpcProvider, Contract } = await import("starknet");
  const { PRIVACY_POOL_ABI } = await import("./types.js");

  const provider = new RpcProvider({ nodeUrl: rpc });
  console.log(`Verifying deployment on ${rpc}...\n`);

  const checks: { name: string; ok: boolean; detail: string }[] = [];

  // Check pool contract responds
  try {
    const pool = new Contract(PRIVACY_POOL_ABI as any, poolAddr, provider);
    const root = await pool.call("get_root");
    checks.push({ name: "PrivacyPool.get_root()", ok: true, detail: `root=${root}` });
  } catch (e: any) {
    checks.push({ name: "PrivacyPool.get_root()", ok: false, detail: e.message });
  }

  try {
    const pool = new Contract(PRIVACY_POOL_ABI as any, poolAddr, provider);
    const count = await pool.call("get_leaf_count");
    checks.push({ name: "PrivacyPool.get_leaf_count()", ok: true, detail: `leaves=${count}` });
  } catch (e: any) {
    checks.push({ name: "PrivacyPool.get_leaf_count()", ok: false, detail: e.message });
  }

  // Check stealth registry if provided
  if (flags.stealth) {
    try {
      const { STEALTH_REGISTRY_ABI } = await import("./types.js");
      const reg = new Contract(STEALTH_REGISTRY_ABI as any, flags.stealth, provider);
      const count = await reg.call("get_ephemeral_count");
      checks.push({ name: "StealthRegistry.get_ephemeral_count()", ok: true, detail: `count=${count}` });
    } catch (e: any) {
      checks.push({ name: "StealthRegistry.get_ephemeral_count()", ok: false, detail: e.message });
    }
  }

  // Check epoch manager if provided
  if (flags.epochs) {
    try {
      const { EPOCH_MANAGER_ABI } = await import("./types.js");
      const epoch = new Contract(EPOCH_MANAGER_ABI as any, flags.epochs, provider);
      const current = await epoch.call("get_current_epoch");
      checks.push({ name: "EpochManager.get_current_epoch()", ok: true, detail: `epoch=${current}` });
    } catch (e: any) {
      checks.push({ name: "EpochManager.get_current_epoch()", ok: false, detail: e.message });
    }
  }

  // Print results
  let allOk = true;
  for (const c of checks) {
    const icon = c.ok ? "✓" : "✗";
    console.log(`  ${icon} ${c.name} — ${c.detail}`);
    if (!c.ok) allOk = false;
  }

  console.log("");
  if (allOk) {
    console.log("All checks passed!");
  } else {
    console.log("Some checks failed — review above.");
    process.exit(1);
  }
}

// ─── Main ────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.length === 0) usage();

  const { command, positional, flags } = parseArgs(args);

  switch (command) {
    case "keygen":
      await cmdKeygen();
      break;
    case "deposit":
      await cmdDeposit(positional, flags);
      break;
    case "transfer":
      await cmdTransfer(positional, flags);
      break;
    case "withdraw":
      await cmdWithdraw(positional, flags);
      break;
    case "balance":
      await cmdBalance(flags);
      break;
    case "info":
      await cmdInfo(flags);
      break;
    case "stealth-register":
      await cmdStealthRegister(flags);
      break;
    case "stealth-scan":
      await cmdStealthScan(flags);
      break;
    case "bridge-l1":
      await cmdBridgeL1(positional, flags);
      break;
    case "epoch":
      await cmdEpoch(flags);
      break;
    case "backup":
      await cmdBackup(positional, flags);
      break;
    case "restore":
      await cmdRestore(positional, flags);
      break;
    case "verify-backup":
      await cmdVerifyBackup(positional, flags);
      break;
    case "verify-deployment":
      await cmdVerifyDeployment(flags);
      break;
    default:
      console.error(`Unknown command: ${command}`);
      usage();
  }
}

main().catch((err) => {
  console.error("Fatal:", err.message ?? err);
  process.exit(1);
});
