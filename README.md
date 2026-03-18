# StarkPrivacy

[![CI](https://github.com/Soul-Research-Labs/Answe/actions/workflows/ci.yml/badge.svg)](https://github.com/Soul-Research-Labs/Answe/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Cairo](https://img.shields.io/badge/Cairo-2.16-orange.svg)](https://book.cairo-lang.org)
[![Starknet](https://img.shields.io/badge/Starknet-Sepolia-blueviolet.svg)](https://starknet.io)
[![Tests](https://img.shields.io/badge/tests-473%20passing-brightgreen.svg)](#testing)

**A unified ZK privacy protocol for the Starknet ecosystem** — combining privacy pool mechanics, stealth addresses, cross-chain bridging, and STARK-native cryptography into a single coherent protocol.

StarkPrivacy lets users **deposit** tokens into a shielded pool, execute **private transfers** with zero-knowledge STARK proofs, **withdraw** to any address without revealing the sender, and **bridge notes** across Ethereum L1, Starknet L2, and Madara appchains — all with no trusted setup and no ceremony.

| What you get             | How it works                                                |
| ------------------------ | ----------------------------------------------------------- |
| 🔒 **Shielded balances** | Poseidon-hashed note commitments in a depth-32 Merkle tree  |
| 🔄 **Private transfers** | 2-in-2-out UTXO model, STARK-proven on-chain                |
| 🕵️ **Stealth addresses** | ECDH one-time addresses with trial-scan for recipients      |
| 🌉 **Cross-chain notes** | ZK-Bound State Locks — lock on one chain, unlock on another |
| 🛡️ **No trusted setup**  | Pure STARK proofs; no toxic waste, quantum-resistant        |

---

## Table of Contents

- [Architecture](#architecture)
- [Features](#features)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Deployment](#deployment)
- [Operational Scripts](#operational-scripts)
- [SDK Usage](#sdk-usage)
- [Testing](#testing)
- [Cairo Crate Reference](#cairo-crate-reference)
- [Key Design Decisions](#key-design-decisions)
- [Roadmap](#roadmap)
- [Documentation](#documentation)
- [Security](#security)
- [Contributing](#contributing)
- [License](#license)

---

## Architecture

```
                    ┌────────────────────┐
                    │  @starkprivacy/sdk │
                    │  starknet.js client│
                    └────────┬───────────┘
                             │
┌────────────────────────────▼────────────────────────────────┐
│              Cairo Smart Contracts (on-chain)               │
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ PrivacyPool │  │ NullifierReg │  │ EpochManager      │  │
│  │ deposit()   │  │ domain-sep   │  │ epoch roots       │  │
│  │ transfer()  │  │ V2 nullifier │  │ finalization      │  │
│  │ withdraw()  │  │              │  │                   │  │
│  └──────┬──────┘  └──────┬───────┘  └───────┬───────────┘  │
│         │                │                  │              │
│  ┌──────▼──────┐  ┌──────▼───────┐  ┌───────▼───────────┐  │
│  │ MerkleTree  │  │ Compliance   │  │ StealthRegistry   │  │
│  │ Poseidon    │  │ Oracle hooks │  │ ECDH one-time     │  │
│  │ depth=32    │  │ policy-bound │  │ addresses         │  │
│  └─────────────┘  └──────────────┘  └───────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ BridgeRouter · L1BridgeAdapter · MadaraAdapter       │  │
│  │ L1↔L2 messaging · ZK-Bound State Locks               │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ KakarotAdapter (EVM↔Cairo)                           │  │
│  │ EVM deposits/transfers/withdrawals · gas translation  │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Security & Governance                                │  │
│  │ RateLimiter · ReentrancyGuard · SanctionsOracle      │  │
│  │ Timelock · MultiSig (M-of-N) · UpgradeableProxy      │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Features

### Privacy Pool (2-in-2-out UTXO)

- **Deposit** — Shield tokens by committing them to an on-chain Merkle tree; real ERC-20 escrow via `IERC20Dispatcher`
- **Transfer** — Private transfers using zero-knowledge proofs (2-in 2-out, balance conserved in-circuit)
- **Withdraw** — Unshield tokens back to any Starknet address with ZK proof of note ownership and fee routing

### Stealth Addresses

- **Meta-address registration** — Publish spending + viewing public keys on-chain
- **One-time addresses** — Senders derive unique stealth addresses via ECDH
- **Trial scanning** — Recipients detect incoming payments with their viewing key

### Cross-Chain Bridging

- **L1↔L2 messaging** — Privacy-preserving bridges using Starknet's native `send_message_to_l1_syscall`
- **ZK-Bound State Locks** — Lock commitment + amount on source chain, relay proof, unlock on destination with actual bridged value
- **Epoch manager** — Cross-chain nullifier synchronization via sequential Poseidon accumulator roots
- **Madara appchain adapter** — Cross-appchain lock/receive with peer registration and epoch root sync
- **Kakarot EVM adapter** — EVM-compatible deposits/transfers/withdrawals via Kakarot, with gas fee translation

### Security Components

- **Domain-separated nullifiers** — `poseidon(poseidon(sk, cm), poseidon(chain_id, app_id))` prevents cross-chain double-spend
- **Rate limiting** — Per-address sliding window rate limiter (embeddable Cairo component)
- **Reentrancy guards** — Lock-based guard as a reusable Cairo component
- **Compliance oracle** — Sanctions blocklist with optional policy enforcement hooks
- **Metadata resistance** — Fixed-size 64-felt proof envelopes + relay timing jitter
- **Timelock governance** — Delayed-execution admin operations with configurable `min_delay`
- **MultiSig** — M-of-N multisignature governance for protocol upgrades (up to 10 signers)
- **UpgradeableProxy** — UUPS-style upgrade proxy with dual authorization via `replace_class_syscall`
- **Pluggable proof verifier** — `IProofVerifier` interface; `MockVerifier` for testnet, Stone/S-Two for mainnet

### Cryptographic Primitives

- **Poseidon hash** — Native Cairo builtin (zero-cost in-circuit)
- **Pedersen hash** — Native Cairo builtin
- **Depth-32 Merkle tree** — Append-only incremental tree with root history ring buffer
- **STARK proofs** — Transparent setup, no trusted ceremony, quantum-resistant

---

## Project Structure

```
starkprivacy/
├── crates/
│   ├── primitives/     # Poseidon/Pedersen wrappers, note commitment, nullifier
│   ├── tree/           # Depth-32 append-only Merkle tree (Poseidon)
│   ├── nullifier/      # NullifierRegistry contract
│   ├── pool/           # PrivacyPool contract (deposit/transfer/withdraw)
│   ├── stealth/        # StealthRegistry, EncryptedNote, StealthAccountFactory
│   ├── bridge/         # BridgeRouter, L1BridgeAdapter, EpochManager, MadaraAdapter, KakarotAdapter
│   ├── compliance/     # IComplianceOracle, SanctionsOracle
│   ├── circuits/       # TransferCircuit, WithdrawCircuit, Verifier, Metadata
│   └── security/       # RateLimiter, ReentrancyGuard, Timelock, MultiSig, UpgradeableProxy
├── sdk/                # @starkprivacy/sdk — TypeScript SDK + CLI
│   ├── src/
│   │   ├── crypto.ts       # Poseidon/Pedersen wrappers (starknet.js)
│   │   ├── keys.ts         # Key management (spending, viewing, owner hash)
│   │   ├── notes.ts        # Note tracking, coin selection, encrypted persistence
│   │   ├── stealth.ts      # Stealth address derivation & scanning
│   │   ├── prover.ts       # Client-side proof generation & Merkle tree
│   │   ├── relayer.ts      # Relayer service scaffold (job queue, validation)
│   │   ├── metadata.ts     # Metadata resistance (envelopes, batch, jitter)
│   │   ├── indexer.ts      # Event indexer + block scanning for note & stealth detection
│   │   ├── stone-prover.ts # Stone-prover / S-Two integration backends
│   │   ├── client.ts       # StarkPrivacyClient — main entry point
│   │   ├── cli.ts          # CLI tool
│   │   ├── types.ts        # ABIs, ContractAddresses, types
│   │   └── index.ts        # Public exports
│   └── src/__tests__/      # 271+ unit + integration tests
├── contracts/evm/      # Solidity bridge: StarkPrivacyBridge.sol + Foundry tests
├── tests/              # Cairo integration + fuzz tests (snforge)
├── scripts/            # Operational scripts (deploy, devnet, monitor, pause, upgrade,
│                       # rollback, key-rotation, setup-governance)
├── docs/               # Protocol spec, formal invariants, TLA+ specs, security checklist,
│                       # gas benchmarks, incident response, deployment runbook, governance ops
├── .github/workflows/  # CI/CD pipeline
├── Scarb.toml          # Cairo workspace configuration
└── snfoundry.toml      # Starknet Foundry configuration
```

---

## Prerequisites

| Tool                   | Version  | Install                                                                                                                |
| ---------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------- |
| **Scarb**              | ≥ 2.16.0 | `curl --proto '=https' --tlsv1.2 -sSf https://docs.swmansion.com/scarb/install.sh \| sh`                               |
| **Starknet Foundry**   | ≥ 0.57.0 | `curl -L https://raw.githubusercontent.com/foundry-rs/starknet-foundry/master/scripts/install.sh \| sh && snfoundryup` |
| **Node.js**            | ≥ 20.0   | https://nodejs.org                                                                                                     |
| **Forge (Foundry)**    | ≥ 0.2    | `curl -L https://foundry.paradigm.xyz \| bash && foundryup`                                                            |
| **starknet-devnet-rs** | latest   | `cargo install starknet-devnet` (integration tests only)                                                               |

---

## Quick Start

### 1. Build Cairo Contracts

```bash
scarb build
```

Compiled artifacts are written to `target/dev/`. Key contracts:

| Artifact                        | Description                  |
| ------------------------------- | ---------------------------- |
| `starkprivacy_PrivacyPool`      | Core privacy pool            |
| `starkprivacy_BridgeRouter`     | Cross-chain ZK lock/unlock   |
| `starkprivacy_KakarotAdapter`   | EVM↔Cairo bridge             |
| `starkprivacy_MadaraAdapter`    | Madara appchain bridge       |
| `starkprivacy_EpochManager`     | Nullifier epoch accumulator  |
| `starkprivacy_MultiSig`         | M-of-N governance            |
| `starkprivacy_Timelock`         | Delayed execution governance |
| `starkprivacy_UpgradeableProxy` | UUPS upgrade proxy           |
| `starkprivacy_MockVerifier`     | Testnet proof verifier       |

### 2. Run Cairo Tests

```bash
# All integration tests (190 tests incl. 15 fuzz × 256 runs)
snforge test

# Full workspace including unit crates (237 total)
snforge test --workspace

# Tests for a specific crate
snforge test -p starkprivacy_pool
snforge test -p starkprivacy_bridge
snforge test -p starkprivacy_security
```

### 3. Build & Test the SDK

```bash
cd sdk
npm install
npm run build
npm test          # 258 passing, 9 skipped
```

### 4. Run EVM Bridge Tests

```bash
cd contracts/evm
forge test        # 25 passing
```

### 5. Use the CLI

```bash
# Generate a new key pair
npx starkprivacy keygen

# Deposit into privacy pool
npx starkprivacy deposit 1000 \
  --key 0x<spending_key> \
  --pool 0x<pool_address> \
  --rpc https://starknet-sepolia.public.blastapi.io/rpc/v0_7

# Private transfer
npx starkprivacy transfer 0x<recipient_owner_hash> 700 \
  --key 0x<spending_key> --pool 0x<pool_address>

# Withdraw to public address
npx starkprivacy withdraw 0x<recipient_address> 300 \
  --key 0x<spending_key> --pool 0x<pool_address>

# Check shielded balance
npx starkprivacy balance --key 0x<spending_key> --pool 0x<pool_address>

# Register stealth meta-address
npx starkprivacy stealth-register \
  --key 0x<spending_key> --stealth 0x<stealth_registry>

# Scan for incoming stealth payments
npx starkprivacy stealth-scan \
  --key 0x<spending_key> --stealth 0x<stealth_registry>

# Bridge to L1
npx starkprivacy bridge-l1 0x<commitment> 0x<l1_recipient> 1000 \
  --key 0x<spending_key> --l1bridge 0x<bridge_address>

# Check current epoch
npx starkprivacy epoch --epochs 0x<epoch_manager>
```

---

## Deployment

### Local Devnet

```bash
# Start starknet-devnet-rs
./scripts/devnet.sh

# Stop devnet
./scripts/devnet.sh --stop
```

### Starknet Sepolia

```bash
# 1. Create and fund a deployer account
sncast account create --url https://starknet-sepolia.public.blastapi.io/rpc/v0_7 --name deployer
sncast account deploy --url https://starknet-sepolia.public.blastapi.io/rpc/v0_7 --name deployer --max-fee 0.01

# 2. Set environment variables
export STARKNET_RPC_URL="https://starknet-sepolia.public.blastapi.io/rpc/v0_7"
export STARKNET_ACCOUNT="deployer"

# 3. Deploy all contracts
./scripts/deploy.sh --network sepolia
```

The deployment script outputs a JSON manifest (`scripts/deployments-sepolia.json`) with all contract addresses.

See the full step-by-step guide in [docs/sepolia-deployment-runbook.md](docs/sepolia-deployment-runbook.md).

---

## Operational Scripts

All scripts are in `scripts/` and read env vars for non-interactive CI use.

| Script                                                       | Purpose                                            |
| ------------------------------------------------------------ | -------------------------------------------------- |
| [`scripts/deploy.sh`](scripts/deploy.sh)                     | Deploy all contracts to Sepolia or mainnet         |
| [`scripts/devnet.sh`](scripts/devnet.sh)                     | Start / stop local starknet-devnet-rs              |
| [`scripts/monitor.sh`](scripts/monitor.sh)                   | Real-time event monitoring and health checks       |
| [`scripts/setup-governance.sh`](scripts/setup-governance.sh) | Wire MultiSig + Timelock post-deploy               |
| [`scripts/pause.sh`](scripts/pause.sh)                       | Emergency pause / unpause (pool, bridge, adapters) |
| [`scripts/upgrade.sh`](scripts/upgrade.sh)                   | Declare new class hash and call `upgrade()`        |
| [`scripts/rollback.sh`](scripts/rollback.sh)                 | Pause then revert to a previous class hash         |
| [`scripts/key-rotation.sh`](scripts/key-rotation.sh)         | Transfer owner or rotate operator address          |

**Emergency pause** (requires `POOL_ADDRESS` env var):

```bash
export STARKNET_RPC_URL="..."
export STARKNET_ACCOUNT="deployer"
export POOL_ADDRESS="0x..."

./scripts/pause.sh pause    # halt all operations
./scripts/pause.sh unpause  # resume after incident
```

**Contract upgrade**:

```bash
export BRIDGE_ROUTER_ADDRESS="0x..."
./scripts/upgrade.sh --contract bridge --network sepolia
```

**Rollback** (pauses first, then reverts to a known-good class hash):

```bash
./scripts/rollback.sh --contract pool --class-hash 0x<prev_hash>
```

---

## SDK Usage

### TypeScript

```typescript
import { StarkPrivacyClient, KeyManager } from "@starkprivacy/sdk";

// Generate keys
const keys = KeyManager.generate();
console.log("Owner hash:", keys.exportKeys(true).ownerHash.toString(16));

// Create client
const client = StarkPrivacyClient.fromSpendingKey(
  {
    rpcUrl: "https://starknet-sepolia.public.blastapi.io/rpc/v0_7",
    contracts: {
      pool: "0x...",
      stealthRegistry: "0x...",
      l1Bridge: "0x...",
      epochManager: "0x...",
    },
    chainId: 0x534e5f5345504f4c4941n,
    appId: 0x535441524b505249564143n,
    account: {
      address: "0x...",
      privateKey: "0x...",
    },
  },
  keys.exportKeys(true).spendingKey,
);

// Shield tokens (applies relay jitter for timing metadata resistance)
const { note, txHash } = await client.deposit(1000n);

// Private transfer
const { outputNotes } = await client.transfer(recipientOwnerHash, 700n);

// Withdraw to public address
const { changeNote } = await client.withdraw("0xRecipient", 300n);

// Stealth send
const { stealth } = await client.stealthSend(recipientMeta, 500n);

// Scan for incoming stealth payments
const found = await client.scanStealthNotes(mySpendingPubKey);

// Bridge to L1 (locks actual amount + asset_id on-chain)
const bridgeTx = await client.bridgeToL1(commitment, l1Recipient, amount);

// Query epoch state
const epoch = await client.getCurrentEpoch();
const root = await client.getEpochRoot(epoch);
```

### Relayer Service

```typescript
import { Relayer } from "@starkprivacy/sdk";

const relayer = new Relayer({
  rpcUrl: "https://starknet-sepolia.public.blastapi.io/rpc/v0_7",
  account: { address: "0x...", privateKey: "0x..." },
  contracts: { pool: "0x..." },
  minFee: 100n,
  maxPending: 50,
  maxRetries: 3,
});

// Submit a proof bundle (applies timing jitter before submission)
const jobId = await relayer.submit(proofRequest);

// Poll status
const job = await relayer.getJob(jobId);
console.log(job?.status); // "pending" | "submitted" | "confirmed" | "failed"

// Get aggregate stats
const stats = await relayer.getStats();

// Recover jobs after restart
const recovered = await relayer.recover();
```

---

## Testing

| Suite                                             | Count         | Command                                         |
| ------------------------------------------------- | ------------- | ----------------------------------------------- |
| Cairo integration                                 | 190           | `snforge test`                                  |
| Cairo full workspace (incl. unit crates)          | 237           | `snforge test --workspace`                      |
| — bridge (BridgeRouter + EpochManager)            | 12            | included above                                  |
| — cross-chain (Kakarot + Madara)                  | 30            | included above                                  |
| — governance (Timelock + MultiSig)                | 25            | included above                                  |
| — proxy (UpgradeableProxy)                        | 9             | included above                                  |
| — fuzz / property-based                           | 15 × 256 runs | included above                                  |
| SDK unit + integration                            | 258           | `cd sdk && npm test`                            |
| SDK integration (devnet, requires running devnet) | 9 skipped     | `DEVNET_URL=http://127.0.0.1:5050/rpc npm test` |
| EVM bridge (Foundry)                              | 25            | `cd contracts/evm && forge test`                |
| **Total (integration + SDK + EVM)**               | **473**       |                                                 |

### Running Integration Tests Against Devnet

```bash
# Terminal 1
./scripts/devnet.sh

# Terminal 2
cd sdk
DEVNET_URL=http://127.0.0.1:5050/rpc npm test

# Full E2E with deployed contracts
DEVNET_URL=http://127.0.0.1:5050/rpc POOL_ADDRESS=0x... npm test
```

---

## Cairo Crate Reference

### `starkprivacy_primitives`

- `poseidon_hash_2(a, b)`, `poseidon_hash_3(a, b, c)`, `poseidon_hash_4(a, b, c, d)` — Poseidon wrappers
- `compute_note_commitment(owner, value, asset_id, blinding)` — Note commitment
- `compute_nullifier_v2(sk, commitment, chain_id, app_id)` — Domain-separated nullifier

### `starkprivacy_tree`

- `MerkleTree` — Depth-32 append-only incremental Poseidon Merkle tree
- `verify_merkle_proof(root, leaf, index, path)` — Membership proof verification

### `starkprivacy_pool`

- `PrivacyPool` — Main contract: `deposit()`, `transfer()`, `withdraw()`
- Root history ring buffer (100 entries)
- Compliance oracle integration via `IComplianceOracle`
- ERC-20 token escrow via `IERC20Dispatcher` (deposit: `transferFrom`, withdraw: `transfer`)
- Pluggable proof verification via `IProofVerifier` dispatcher
- Pausable by owner: `pause()`, `unpause()`
- Fee recipient configuration: `set_fee_recipient()`
- `MockVerifier` — Validates proof envelope structure and public-input consistency

### `starkprivacy_stealth`

- `StealthRegistry` — Meta-address registration + ephemeral key publishing
- `EncryptedNote` — Fixed-size padded note payloads with scan tags
- `StealthAccountFactory` — One-time AA account deployment via `deploy_syscall`

### `starkprivacy_bridge`

- `BridgeRouter` — ZK-Bound State Lock pattern for cross-chain privacy
- `L1BridgeAdapter` — Ethereum L1↔L2 messaging via `send_message_to_l1_syscall`
- `EpochManager` — Sequential epochs with Poseidon accumulator roots
- `MadaraAdapter` — Cross-appchain adapter: peer registration, lock/receive, epoch root sync
- `KakarotAdapter` — EVM↔Cairo bridge via Kakarot: `evm_deposit()`, `evm_transfer()`, `evm_withdraw()`, gas fee estimation, pause/unpause

### `starkprivacy_circuits`

- `TransferCircuit` — 2-in-2-out STARK-provable transfer constraints
- `WithdrawCircuit` — Transfer + exit value constraint
- `Verifier` — Proof envelope encoding/decoding (transfer=0, withdraw=1)
- `Metadata` — 64-felt fixed-size envelopes with dummy padding

### `starkprivacy_security`

- `RateLimiterComponent` — Per-address sliding window rate limiting
- `ReentrancyGuardComponent` — Simple lock flag guard
- `Timelock` — Delayed execution governance: `queue()`, `execute()`, `cancel()`, configurable `min_delay`
- `MultiSig` — M-of-N multisignature: `propose()`, `approve()`, `revoke()` (up to 10 signers)
- `UpgradeableProxy` — UUPS-style upgrade proxy: `upgrade()`, `set_governor()`, `set_emergency_governor()`, dual-auth with `replace_class_syscall`

### `starkprivacy_compliance`

- `IComplianceOracle` — Interface for policy enforcement hooks
- `SanctionsOracle` — Blocklist-based sanctions compliance

---

## Key Design Decisions

| Decision                            | Rationale                                                                      |
| ----------------------------------- | ------------------------------------------------------------------------------ |
| **Pure Cairo/STARK**                | No trusted setup, quantum-resistant, native verification, best gas efficiency  |
| **felt252 field**                   | All crypto uses Starknet's native field ($p = 2^{251} + 17 \cdot 2^{192} + 1$) |
| **2-in-2-out fixed**                | Simpler MVP; variable I/O (up to 8-in-8-out) planned for v2                    |
| **V2 nullifiers only**              | Domain-separated from start; greenfield, no backward compat needed             |
| **Account Abstraction for stealth** | Deploy one-time smart accounts — more powerful than vanilla derivation         |
| **Mock proofs for MVP**             | Real STARK proof via `stone-prover` or `s-two` backend (scaffold included)     |

---

## Roadmap

- [x] Phase 1: Foundation — Cairo primitives & core contracts
- [x] Phase 2: ZK Circuits — STARK-provable transfer/withdraw constraints
- [x] Phase 3: Stealth Addresses — Encrypted notes, scanning, AA deployment
- [x] Phase 4: Cross-Chain — L1 bridge adapter, epoch manager
- [x] Phase 5: TypeScript SDK & CLI
- [x] Phase 6: Security hardening — rate limiting, reentrancy, compliance, metadata resistance, fee routing
- [x] Phase 7: Stone-prover / S-Two integration scaffold (`ProverBackend` interface)
- [x] Phase 9: Madara appchain adapter
- [x] Phase 10: Kakarot EVM adapter (Solidity + snforge tests)
- [x] Phase 11: Governance wiring — MultiSig → Timelock → cross-contract execution
- [x] Phase 12: SDK production hardening — prover integration, retry logic, nonce management, bias fixes
- [x] Phase 13: Testing & quality — 15 fuzz tests (256 runs), edge-case suite, 473+ total tests
- [x] Phase 15: Mainnet readiness — deployment runbooks, script safety gates, formal invariants
- [x] Phase 16: P0/P1 fixes — bridge amount encoding, metadata jitter integration, operational scripts (pause, upgrade, rollback, key-rotation)
- [ ] Phase 8: Starknet Sepolia testnet deployment (contracts live on-chain)
- [ ] Phase 14: Formal verification & audit ([29 invariants](docs/formal-invariants.md), [TLA+ specs](docs/formal-specs.md))
- [ ] Phase 17: Mainnet deployment — production governance signers, Stone verifier on-chain, monitoring

---

## Documentation

| Document                                                                 | Description                                                        |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------ |
| [Protocol Specification](docs/protocol-spec.md)                          | Cryptographic primitives, circuit constraints, contract interfaces |
| [Formal Invariants](docs/formal-invariants.md)                           | 29 named invariants with verification status                       |
| [Formal Specs (TLA+)](docs/formal-specs.md)                              | Machine-checkable specifications for critical properties           |
| [Security Checklist](docs/security-checklist.md)                         | Full-stack security self-assessment                                |
| [Incident Response](docs/incident-response.md)                           | Severity levels, playbooks, key rotation procedures                |
| [Governance Operations](docs/governance-operations.md)                   | MultiSig → Timelock operational workflow                           |
| [Deployment Runbook](docs/sepolia-deployment-runbook.md)                 | Step-by-step deployment with mainnet promotion checklist           |
| [Gas Benchmarks](docs/gas-benchmarks.md)                                 | L2/L1 gas measurements for all operations                          |
| [Mainnet Readiness Tracker](docs/mainnet-readiness-execution-tracker.md) | Phase-by-phase execution tracker and sign-off matrix               |
| [Readiness Report](docs/readiness-verification-report.md)                | Final verification matrix results                                  |
| [SDK Guide](sdk/README.md)                                               | Operator integration guide for relayer, indexer, CLI               |

---

## Security

See [SECURITY.md](SECURITY.md) for vulnerability disclosure policy and contact information.

**Do NOT open public issues for security vulnerabilities.**

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, code style, and PR process.

---

## License

[MIT](LICENSE) — Copyright © 2025–2026 Soul Research Labs
