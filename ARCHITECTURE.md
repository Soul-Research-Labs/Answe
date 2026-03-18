# Architecture Overview

This document describes the high-level architecture of StarkPrivacy.

## System Layers

```
┌─────────────────────────────────────────────────────────┐
│                     User / CLI                           │
├─────────────────────────────────────────────────────────┤
│                  TypeScript SDK                          │
│  KeyManager · NoteManager · Prover · Relayer · Indexer   │
├─────────────────────────────────────────────────────────┤
│                  Relayer Service                         │
│  Envelope batching · Dummy padding · Jitter · Submission │
├──────────────┬──────────────────────┬───────────────────┤
│  Starknet L2 │    Madara L3         │   Ethereum L1     │
│  (Contracts) │  (Appchain Peers)    │   (L1 Bridge)     │
└──────────────┴──────────────────────┴───────────────────┘
```

## Contract Architecture

```
UpgradeableProxy (governor = Timelock, emergency_governor = deployer)
  └── PrivacyPool
        ├── NullifierRegistry    (double-spend prevention)
        ├── MerkleTree           (depth-32 Poseidon)
        ├── Verifier             (STARK proof verification)
        ├── ReentrancyGuard      (withdraw protection)
        └── RateLimiter          (per-address operation limits)

Governance Pipeline
  MultiSig (M-of-N) ──→ Timelock (delayed execution) ──→ Target Contract

Bridge Layer
  BridgeRouter ──→ EpochManager ──→ MadaraAdapter (L3 peers)
                                 └── L1BridgeAdapter (Ethereum)
                                 └── KakarotAdapter (EVM compatibility)

Compliance
  SanctionsOracle (pluggable, deposit-time check)

Stealth
  StealthRegistry (ephemeral key publication + scan tags)
```

## Crate Map

| Crate        | Path                  | Purpose                                  |
| ------------ | --------------------- | ---------------------------------------- |
| `primitives` | `crates/primitives/`  | Poseidon, Pedersen, commitment, nullifier |
| `tree`       | `crates/tree/`        | Depth-32 Merkle tree with root history    |
| `circuits`   | `crates/circuits/`    | Transfer and withdraw circuit constraints |
| `pool`       | `crates/pool/`        | PrivacyPool contract (deposit/transfer/withdraw) |
| `nullifier`  | `crates/nullifier/`   | NullifierRegistry contract               |
| `stealth`    | `crates/stealth/`     | StealthRegistry + encrypted note scanning |
| `bridge`     | `crates/bridge/`      | BridgeRouter, EpochManager, L1/Madara/Kakarot adapters |
| `compliance` | `crates/compliance/`  | SanctionsOracle contract                 |
| `security`   | `crates/security/`    | ReentrancyGuard, RateLimiter components  |

## SDK Architecture

| Module           | File              | Responsibility                            |
| ---------------- | ----------------- | ----------------------------------------- |
| `KeyManager`     | `keys.ts`         | Key derivation (spending, viewing, owner) |
| `NoteManager`    | `notes.ts`        | UTXO tracking, coin selection             |
| `Prover`         | `prover.ts`       | Proof generation (Local/Stone/S2)         |
| `RelayerClient`  | `relayer.ts`      | Job submission with failover              |
| `EventIndexer`   | `indexer.ts`      | On-chain event scanning                   |
| `StealthModule`  | `stealth.ts`      | Stealth address derivation and scanning   |
| `MetadataModule` | `metadata.ts`     | Envelope padding, batching, shuffling     |
| `Crypto`         | `crypto.ts`       | Poseidon/Pedersen wrappers                |
| `CLI`            | `cli.ts`          | Command-line interface                    |

## Data Flow: Private Transfer

1. User calls `client.transfer(recipient, amount)`.
2. `NoteManager` selects two unspent notes (greedy by value).
3. `Prover` generates a ZK proof (2-in-2-out transfer circuit).
4. `MetadataModule` pads the proof to a 64-felt envelope.
5. `RelayerClient` submits the envelope (with optional dummy padding).
6. Relayer batches envelopes, applies jitter, submits to Starknet.
7. `PrivacyPool.transfer()` verifies the proof, records nullifiers, inserts new commitments.
8. Recipient's `EventIndexer` detects the new commitments in a future scan.

## Key Design Decisions

- **Fixed 2-in-2-out fan-in/fan-out**: Hides whether a transaction is a split, merge, or self-transfer.
- **Epoch-based bridging**: Cross-chain transfers are batched per epoch for privacy set accumulation.
- **Relayer model**: Users never call the sequencer directly — preserves sender anonymity.
- **Depth-32 tree**: Supports ~4 billion leaves, sufficient for long-term operation.
- **Domain-separated nullifiers**: Include `chain_id` and `app_id` to prevent cross-chain replay.

## Related Documentation

| Document                      | Description                                    |
| ----------------------------- | ---------------------------------------------- |
| `docs/protocol-spec.md`       | Full protocol specification                    |
| `docs/formal-specs.md`        | TLA⁺-style formal verification specifications  |
| `docs/formal-invariants.md`   | Named invariants with verification status      |
| `docs/security-checklist.md`  | Pre-audit security self-assessment             |
| `docs/gas-benchmarks.md`      | L2/L1 gas measurements                         |
| `docs/governance-operations.md` | Governance operational runbook                |
| `docs/incident-response.md`   | Incident response procedures                   |
| `docs/sepolia-deployment-runbook.md` | Deployment guide                         |
