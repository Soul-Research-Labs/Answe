# @starkprivacy/sdk

TypeScript SDK for StarkPrivacy — a ZK privacy protocol on Starknet.

## Requirements

- Node.js ≥ 20
- A Starknet RPC endpoint (Sepolia or mainnet)
- Deployed StarkPrivacy contracts (see `docs/sepolia-deployment-runbook.md`)

## Installation

```bash
npm install @starkprivacy/sdk
```

## Quick Start

### Key Generation

```typescript
import { KeyManager } from "@starkprivacy/sdk";

const km = KeyManager.generate();
const keys = km.exportKeys(true);
console.log("Spending key:", keys.spendingKey.toString(16));
console.log("Viewing key:", keys.viewingKey.toString(16));
console.log("Owner hash:", keys.ownerHash.toString(16));
```

### Client Setup

```typescript
import { StarkPrivacyClient, createProver } from "@starkprivacy/sdk";

const client = StarkPrivacyClient.fromSpendingKey(
  {
    rpcUrl: "https://starknet-sepolia.public.blastapi.io/rpc/v0_7",
    contracts: {
      pool: "0x<POOL_ADDRESS>",
      stealthRegistry: "0x<STEALTH_REG>",
      l1Bridge: "0x<L1_BRIDGE>",
    },
    chainId: 0x534e5f5345504f4c4941n, // SN_SEPOLIA
    appId: 0x535441524b505249564143n,
    account: {
      address: "0x<YOUR_ACCOUNT>",
      privateKey: "0x<YOUR_PRIVATE_KEY>",
    },
    prover: createProver("local"), // Use "stone" or "s-two" for production
  },
  spendingKey,
);
```

### Deposit

```typescript
const tx = await client.deposit(1000n, 0n); // amount, assetId
console.log("Deposit tx:", tx.transaction_hash);
```

### Transfer

```typescript
const tx = await client.transfer(recipientOwnerHash, 500n);
console.log("Transfer tx:", tx.transaction_hash);
```

### Withdraw

```typescript
const tx = await client.withdraw(recipientAddress, 300n, 0n); // addr, amount, assetId
console.log("Withdraw tx:", tx.transaction_hash);
```

## Operator Guide

### Running a Relayer

The relayer submits withdrawal transactions on behalf of users, collecting a fee.

```typescript
import { Relayer, SqliteJobStorage } from "@starkprivacy/sdk";

const relayer = new Relayer({
  rpcUrl: "https://starknet-sepolia.public.blastapi.io/rpc/v0_7",
  account: {
    address: "0x<RELAYER_ACCOUNT>",
    privateKey: "0x<RELAYER_KEY>", // Use KMS on mainnet
  },
  contracts: { pool: "0x<POOL_ADDRESS>" },
  minFee: 100n, // Minimum fee to accept a job
  maxPending: 50, // Backpressure limit
  maxRetries: 3, // Retry failed transactions
  storage: new SqliteJobStorage("./relayer-jobs.db"),
});

// Start processing
await relayer.start();
```

**Production considerations:**

- Use `SqliteJobStorage` (not `InMemoryJobStorage`) for crash recovery.
- Job IDs are monotonic and restart-safe — the counter persists in a `relayer_meta` table.
- Jobs execute in deterministic order (`ORDER BY created_at, id`).
- Private keys should be managed via KMS or encrypted keystore, never plaintext.

### Running an Indexer

The indexer scans on-chain events to detect deposits, nullifiers, and stealth payments.

```typescript
import { EventIndexer } from "@starkprivacy/sdk";

const indexer = new EventIndexer(
  "https://starknet-sepolia.public.blastapi.io/rpc/v0_7",
  "0x<POOL_ADDRESS>",
  "0x<STEALTH_REGISTRY>", // optional
);

// Full scan from genesis
const result = await indexer.scanBlocks(0);
console.log(
  `Found ${result.deposits} deposits, ${result.nullifiers} nullifiers`,
);

// Incremental scan (resumes from last scanned block)
const incremental = await indexer.scanBlocks();
```

**Notes:**

- `scanBlocks()` with no arguments resumes from `lastBlockScanned + 1`.
- Events are not deduplicated — avoid scanning overlapping block ranges.
- The indexer does not persist state; save `getProgress().lastBlockScanned` externally for restarts.

### Prover Backends

| Backend | Usage                                 | When to Use                           |
| ------- | ------------------------------------- | ------------------------------------- |
| `local` | `createProver("local")`               | Development and testing only          |
| `stone` | `createProver("stone", { endpoint })` | Production — STARK prover             |
| `s-two` | `createProver("s-two", { endpoint })` | Production — alternative STARK prover |

All remote prover responses are strictly validated: felt252 range checks, proof structure validation, and explicit public input index mapping for withdraw proofs.

### Stealth Addresses

```typescript
import {
  deriveStealthAddress,
  encryptNote,
  tryScanNote,
} from "@starkprivacy/sdk";

// ─── Sender: create a stealth payment ───────────────
// Recipient publishes their meta-address (S, V) publicly
const recipientMeta = { S: spendingPubKey, V: viewingPubKey };

// Derive a one-time stealth address
const stealth = deriveStealthAddress(recipientMeta);
// stealth.stealthOwnerHash → use as `ownerHash` in the deposit commitment
// stealth.ephemeralPubKey  → publish on StealthRegistry
// stealth.encryptedPayload → attach to the transaction envelope

// Register the ephemeral key on-chain (via the client)
await client.publishEphemeralKey(stealth.ephemeralPubKey);

// ─── Recipient: scan for incoming payments ──────────
const indexer = new EventIndexer(rpcUrl, poolAddress, stealthRegistryAddress);
const events = await indexer.scanBlocks(0);

// Try to decrypt each ephemeral key with the viewing key
for (const ephKey of events.ephemeralKeys) {
  const match = tryScanNote(viewingKey, spendingPubKey, ephKey);
  if (match) {
    console.log("Found stealth payment:", match);
  }
}
```

## Error Handling

The SDK throws typed errors for common failure modes:

```typescript
import { StarkPrivacyClient } from "@starkprivacy/sdk";

try {
  await client.withdraw(recipient, 500n, 0n);
} catch (err) {
  if (err instanceof Error) {
    switch (true) {
      case err.message.includes("Insufficient balance"):
        console.error("Not enough unspent notes to cover the withdrawal.");
        break;
      case err.message.includes("nullifier already used"):
        console.error("Double-spend detected — note already consumed.");
        break;
      case err.message.includes("not a known root"):
        console.error("Stale Merkle root. Re-sync notes and retry.");
        break;
      default:
        console.error("Unexpected error:", err.message);
    }
  }
}
```

**Common error scenarios:**

| Error                                 | Cause                            | Resolution                                  |
| ------------------------------------- | -------------------------------- | ------------------------------------------- |
| `Insufficient balance`                | Not enough unspent notes         | Wait for pending deposits to confirm        |
| `nullifier already used`              | Note already spent               | Refresh note set with `scanBlocks()`        |
| `not a known root`                    | Root expired from history buffer | Re-sync and rebuild proof with current root |
| `Contract is paused`                  | Emergency pause active           | Wait for protocol to unpause                |
| `RelayerClient: all endpoints failed` | Relayer(s) unreachable           | Check relayer status or switch endpoints    |

## Compatibility

| Runtime      | Supported | Notes                                         |
| ------------ | --------- | --------------------------------------------- |
| Node.js ≥ 20 | ✅        | Primary target — full support                 |
| Bun          | ✅        | Tested with Bun 1.x                           |
| Deno         | ⚠️        | Untested — should work with `npm:` specifiers |
| Browser      | ❌        | Not supported — requires Node.js crypto + fs  |

**Key dependencies:**

- `starknet.js` — Starknet RPC and account management
- `better-sqlite3` — Relayer job persistence (optional, Node.js only)
- No native addons — pure TypeScript

## CLI

```bash
npx starkprivacy keygen                           # Generate key pair
npx starkprivacy deposit <amount> --pool 0x... --key 0x...
npx starkprivacy transfer <recipient> <amount> --pool 0x... --key 0x...
npx starkprivacy withdraw <address> <amount> --pool 0x... --key 0x...
npx starkprivacy balance --pool 0x... --key 0x...
npx starkprivacy info --pool 0x...
npx starkprivacy epoch --pool 0x...
npx starkprivacy stealth-register --key 0x...
npx starkprivacy stealth-scan --key 0x...
npx starkprivacy bridge-l1 <commitment> <l1addr> <amount> --key 0x...
npx starkprivacy backup <file> --key 0x... --password <pw>
npx starkprivacy restore <file> --password <pw>
npx starkprivacy verify-backup <file> --password <pw>
npx starkprivacy verify-deployment --pool 0x...
```

## Development

```bash
cd sdk
npm ci
npm run lint    # Type-check
npm test        # Run all tests
npm run build   # Compile to dist/
npm run docs    # Generate TypeDoc API docs
```

## License

MIT
