# StarkPrivacy

**A unified ZK privacy protocol for the Starknet ecosystem** — combining privacy pool mechanics, stealth addresses, cross-chain bridging, and STARK-native cryptography into a single coherent protocol.

StarkPrivacy port the core concepts from **ZAseon** (cross-chain ZK privacy middleware) and **Lumora** (privacy coprocessor with privacy pool + stealth addresses) into a Starknet-native implementation using **pure Cairo/STARK circuits**.

---

## Architecture

```
                    ┌────────────────────┐
                    │  @starkprivacy/sdk │
                    │  starknet.js client│
                    └────────┬───────────┘
                             │
┌────────────────────────────▼────────────────────────────────┐
│              Cairo Smart Contracts (on-chain)                │
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ PrivacyPool │  │ NullifierReg │  │ EpochManager      │  │
│  │ deposit()   │  │ domain-sep   │  │ epoch roots       │  │
│  │ transfer()  │  │ V2 nullifier │  │ finalization      │  │
│  │ withdraw()  │  │              │  │                   │  │
│  └──────┬──────┘  └──────┬───────┘  └───────┬───────────┘  │
│         │                │                   │              │
│  ┌──────▼──────┐  ┌──────▼───────┐  ┌───────▼───────────┐  │
│  │ MerkleTree  │  │ Compliance   │  │ StealthRegistry   │  │
│  │ Poseidon    │  │ Oracle hooks │  │ ECDH one-time     │  │
│  │ depth=32    │  │ policy-bound │  │ addresses         │  │
│  └─────────────┘  └──────────────┘  └───────────────────┘  │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ BridgeRouter / L1BridgeAdapter                      │    │
│  │ L1↔L2 messaging · Madara inter-chain                │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Security & Governance                               │    │
│  │ RateLimiter · ReentrancyGuard · SanctionsOracle     │    │
│  │ Timelock · MultiSig (M-of-N)                        │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Features

### Privacy Pool (2-in-2-out UTXO model)

- **Deposit** — Shield tokens by committing them to an on-chain Merkle tree
- **Transfer** — Private transfers using zero-knowledge proofs (spend 2 input notes, create 2 output notes)
- **Withdraw** — Unshield tokens back to any Starknet address with ZK proof of note ownership

### Stealth Addresses

- **Meta-address registration** — Publish spending + viewing public keys on-chain
- **One-time addresses** — Senders derive unique stealth addresses via ECDH
- **Trial scanning** — Recipients detect incoming payments with their viewing key

### Cross-Chain Bridging

- **L1↔L2 messaging** — Privacy-preserving bridges using Starknet's native `send_message_to_l1`
- **Epoch manager** — Cross-chain nullifier synchronization via Poseidon accumulators
- **ZK-Bound State Locks** — Lock state on one chain, unlock on another with ZK proof

### Security

- **Domain-separated nullifiers** — `Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))` prevents cross-chain double-spend
- **Rate limiting** — Per-address sliding window rate limiter (embeddable component)
- **Reentrancy guards** — Lock-based guard as a reusable Cairo component
- **Compliance oracle** — Sanctions blocklist with optional policy enforcement hooks
- **Metadata resistance** — Fixed-size 64-felt proof envelopes with dummy padding
- **Timelock governance** — Delayed-execution admin operations with configurable delay
- **MultiSig** — M-of-N multisignature governance for protocol upgrades
- **Pausable pool** — Owner can pause/unpause deposits, transfers, and withdrawals
- **ERC-20 integration** — Real token transfers via `IERC20Dispatcher` (configurable; zero-address = balance-tracking only)
- **Proof verifier** — Pluggable `IProofVerifier` contract for STARK proof validation (MockVerifier for testnet)
- **Fee routing** — Configurable fee recipient address for relayer compensation

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
│   ├── bridge/         # BridgeRouter, L1BridgeAdapter, EpochManager, MadaraAdapter
│   ├── compliance/     # IComplianceOracle, SanctionsOracle
│   ├── circuits/       # TransferCircuit, WithdrawCircuit, Verifier, Metadata
│   └── security/       # RateLimiter, ReentrancyGuard, Timelock, MultiSig
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
│   └── src/__tests__/      # 154 unit + integration tests
├── contracts/
│   └── evm/                # Kakarot EVM adapter (Solidity interfaces)
├── tests/              # Cairo integration + fuzz tests (snforge)
├── scripts/            # Deployment & devnet scripts
├── docs/               # Gas benchmarks, protocol spec, security checklist, formal invariants
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
| **Node.js**            | ≥ 18.0   | https://nodejs.org                                                                                                     |
| **starknet-devnet-rs** | latest   | `cargo install starknet-devnet` (for integration tests)                                                                |

---

## Quick Start

### 1. Build Cairo Contracts

```bash
scarb build
```

Compiled artifacts are written to `target/dev/`:

- `starkprivacy_PrivacyPool.contract_class.json`
- `starkprivacy_NullifierRegistry.contract_class.json`
- `starkprivacy_StealthRegistry.contract_class.json`
- `starkprivacy_StealthAccountFactory.contract_class.json`
- `starkprivacy_BridgeRouter.contract_class.json`
- `starkprivacy_L1BridgeAdapter.contract_class.json`
- `starkprivacy_EpochManager.contract_class.json`
- `starkprivacy_SanctionsOracle.contract_class.json`
- `starkprivacy_MadaraAdapter.contract_class.json`
- `starkprivacy_MockVerifier.contract_class.json`
- `starkprivacy_Timelock.contract_class.json`
- `starkprivacy_MultiSig.contract_class.json`

### 2. Run Cairo Tests

```bash
# Run all workspace tests (130 tests, incl. 15 fuzz × 256 runs)
snforge test --workspace

# Run only integration tests
snforge test

# Run tests for a specific crate
snforge test -p starkprivacy_circuits
```

### 3. Build & Test the SDK

```bash
cd sdk

# Install dependencies
npm install

# Build TypeScript
npm run build

# Run tests (154 passing)
npm test
```

### 4. Use the CLI

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
# 1. Create an account
sncast account create --url https://starknet-sepolia.public.blastapi.io/rpc/v0_7 --name deployer
sncast account deploy --url https://starknet-sepolia.public.blastapi.io/rpc/v0_7 --name deployer --max-fee 0.01

# 2. Set environment
export STARKNET_RPC_URL="https://starknet-sepolia.public.blastapi.io/rpc/v0_7"
export STARKNET_ACCOUNT="deployer"

# 3. Deploy all contracts
./scripts/deploy.sh --network sepolia
```

The deployment script outputs a JSON manifest (`scripts/deployments-sepolia.json`) with all contract addresses.

---

## SDK Usage

### TypeScript

```typescript
import { StarkPrivacyClient, KeyManager } from "@starkprivacy/sdk";

// Generate keys
const keys = KeyManager.generate();
console.log("Owner hash:", keys.exportKeys().ownerHash.toString(16));

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
  keys.exportKeys().spendingKey,
);

// Deposit
const { note, txHash } = await client.deposit(1000n);

// Transfer
const { outputNotes } = await client.transfer(recipientOwnerHash, 700n);

// Withdraw
const { changeNote } = await client.withdraw("0xRecipient", 300n);

// Stealth send
const { stealth } = await client.stealthSend(recipientMeta, 500n);

// Scan for stealth payments
const found = await client.scanStealthNotes(mySpendingPubKey);

// Bridge to L1
const bridgeTx = await client.bridgeToL1(commitment, l1Recipient, amount);

// Check epoch
const epoch = await client.getCurrentEpoch();
```

---

## Testing

| Suite                              | Count     | Command                                         |
| ---------------------------------- | --------- | ----------------------------------------------- |
| Cairo unit + integration           | 130       | `snforge test --workspace`                      |
| — governance (Timelock + MultiSig) | 25        | included above                                  |
| — fuzz / property-based            | 15 (×256) | included above                                  |
| SDK unit tests                     | 154       | `cd sdk && npm test`                            |
| SDK integration (devnet)           | 9         | `DEVNET_URL=http://127.0.0.1:5050/rpc npm test` |
| **Total**                          | **300+**  |                                                 |

### Running Integration Tests

Integration tests require a running `starknet-devnet-rs` instance:

```bash
# Terminal 1: Start devnet
./scripts/devnet.sh

# Terminal 2: Run integration tests
cd sdk
DEVNET_URL=http://127.0.0.1:5050/rpc npm test

# For full E2E with deployed contracts:
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
- [x] Phase 6: Security hardening — Rate limiting, reentrancy, compliance, metadata resistance, fee routing
- [x] Phase 7: Stone-prover / S-Two integration scaffold (ProverBackend interface)
- [ ] Phase 8: Starknet Sepolia testnet deployment
- [x] Phase 9: Madara appchain adapter
- [x] Phase 10: Kakarot EVM adapter (Solidity interfaces)
- [x] Phase 11: Governance wiring — MultiSig→Timelock→cross-contract execution, calldata verification
- [x] Phase 12: SDK production hardening — real prover integration, retry logic, nonce management, bias fixes
- [x] Phase 13: Testing & quality — 15 fuzz tests (256 runs), 20 SDK edge-case tests, 300+ total tests
- [~] Phase 14: Formal verification & audit (29 invariants spec'd — [docs/formal-invariants.md](docs/formal-invariants.md))

---

## License

MIT
