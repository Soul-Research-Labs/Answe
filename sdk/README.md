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
import { deriveStealthAddress } from "@starkprivacy/sdk";

// Sender creates a stealth address for the recipient
const stealth = deriveStealthAddress(recipientMetaAddress);

// Recipient scans for incoming payments
const matches = await indexer.scanStealth(viewingKey, spendingPubKey);
```

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
