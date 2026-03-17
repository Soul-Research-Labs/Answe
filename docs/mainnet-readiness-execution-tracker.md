# Mainnet Readiness Execution Tracker

Last updated: 2026-03-17

This file tracks the implementation sequence for mainnet readiness, the commit points for each step, and verification status.

## Baseline Environment Snapshot

- Branch: `main`
- Git working tree: clean at start
- Scarb: `2.16.0`
- snforge: `0.57.0`
- Node.js: `v22.13.1`
- npm: `10.9.2`
- Forge: unavailable (`command not found`)

## Execution Rules

- Complete one step at a time.
- Commit after each completed step.
- Use hybrid commit granularity:
  - Small commits for high-risk code changes.
  - Grouped commits for adjacent docs and supporting test adjustments.
- Push once after all tracked steps are complete.

## Phased Implementation Checklist

### Phase 0 - Baseline and Tracking

- [x] Create readiness execution tracker with baseline toolchain state.
- [x] Confirm command matrix and local blockers.
- [x] Commit Phase 0 completion.

Target commit message:

`chore(plan): add mainnet readiness execution tracker and baseline snapshot`

### Phase 1 - Proof and Cryptography Hardening

- [x] Harden remote prover response validation and envelope mapping.
- [x] Add prover compatibility and failure-path tests.
- [x] Strengthen stealth shared-secret derivation path.
- [x] Add stealth regression/property tests.

Target commit messages:

`feat(prover): harden remote prover contract and error handling`

`test(prover): add endpoint compatibility and envelope validation coverage`

`feat(stealth): strengthen shared-secret derivation`

`test(stealth): add cryptographic regression coverage`

### Phase 2 - Relayer and Bridge Safety

- [x] Finalize relayer durability and restart recovery behavior.
  - [x] Preserve non-zero withdraw `assetId` through proof -> relayer submission path.
- [x] Add relayer resilience tests for retries, stale jobs, and recovery.
- [x] Expand EVM bridge safety matrix (replay, pause, malformed payloads).
- [ ] Expand Cairo cross-chain edge-case coverage.

Target commit messages:

`feat(relayer): complete durable job lifecycle and recovery semantics`

`test(relayer): cover retry, stale, and restart scenarios`

`test(bridge): expand evm bridge safety matrix`

`test(cross-chain): add replay and pause edge-case coverage`

### Phase 3 - Governance and Operations

- [ ] Add governance e2e proposal -> timelock -> execute coverage.
- [ ] Complete governance operations documentation.
- [ ] Complete deployment and monitoring runbook gaps.
- [ ] Add script safety checks and runbook validation notes.

Target commit messages:

`test(governance): add end-to-end timelock execution coverage`

`docs(governance): add operational workflow and failure handling`

`docs(ops): complete deployment and monitoring runbooks`

`chore(ops): add script validation and safety notes`

### Phase 4 - SDK Release Hygiene

- [ ] Improve SDK packaging/release hygiene.
- [ ] Add CLI/indexer integration reliability coverage.
- [ ] Add operator-focused SDK docs.

Target commit messages:

`chore(sdk): improve package and release hygiene`

`test(cli,indexer): add integration reliability coverage`

`docs(sdk): add operator integration guidance`

### Phase 5 - Final Verification and Push

- [ ] Run full verification matrix.
- [ ] Record final readiness verification report.
- [ ] Push all commits to remote.

Target commit messages:

`chore(release): add final readiness verification report`

## Verification Matrix

Run these commands at the phase boundaries and after major protocol changes:

```bash
# Cairo
scarb build
snforge test --workspace

# SDK
cd sdk
npm ci
npm run build
npm test

# EVM bridge (requires Foundry/forge)
cd ../contracts/evm
forge test
```

## Known Local Blockers

- None currently blocking local SDK/Cairo/EVM verification.
