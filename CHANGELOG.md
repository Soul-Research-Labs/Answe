# Changelog

All notable changes to StarkPrivacy are documented here.
This project follows [Semantic Versioning](https://semver.org/) and [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- **Mainnet readiness execution tracker** (`docs/mainnet-readiness-execution-tracker.md`)
- **Readiness verification report** (`docs/readiness-verification-report.md`)
- **Governance operations runbook** (`docs/governance-operations.md`)
- **SDK operator integration guide** (`sdk/README.md`)
- **SECURITY.md** — vulnerability disclosure policy
- **CONTRIBUTING.md** — contributor guide
- **CHANGELOG.md** — this file

### Changed

- **Prover hardening**: strict `parseFelt` / `parseProofResponse` validation for remote provers
- **Stealth hardening**: fail-closed scan behavior, strengthened shared-secret derivation
- **Relayer durability**: monotonic job IDs via `relayer_meta` table, deterministic job ordering
- **Withdraw assetId**: propagated through proof → relayer → storage pipeline (was hardcoded to 0)
- **EVM bridge tests**: converted all 25 tests to forge-std `vm.prank` / `vm.expectRevert` patterns
- **Deploy script**: added mainnet confirmation gate and existing-manifest warning
- **Governance script**: added mainnet confirmation gate
- **Monitor script**: added L1 bridge health check, log rotation
- **SDK package.json**: added `files`, `engines`, `exports`, `prepublishOnly` fields
- **Deployment runbook**: added mainnet promotion checklist, class-hash validation, disaster recovery

### Fixed

- Remote prover response parsing now validates felt252 range and proof structure
- `stone-prover.ts` withdraw envelope uses explicit index mapping (was broad slice)
- `relayer.ts` `submitWithdraw` uses `proof.assetId` instead of hardcoded `"0"`
- SQLite `nextId()` uses persistent counter (was `COUNT(*)` which resets after deletes)

### Security

- Added mainnet safety gates to deployment and governance scripts
- Added signer hygiene validation (distinct signers required on mainnet)
- Strengthened stealth ECDH derivation path

## [0.1.0] — 2025-12-01

### Added

- Initial release: Privacy pool, stealth addresses, cross-chain bridging
- Cairo contracts: PrivacyPool, NullifierRegistry, StealthRegistry, BridgeRouter, EpochManager
- Kakarot EVM adapter, Madara appchain adapter
- Governance: Timelock, MultiSig, UpgradeableProxy
- TypeScript SDK with CLI, prover backends, relayer, indexer
- 237 Cairo tests, 254 SDK tests, 25 EVM bridge tests
- Formal invariants (29 named) and TLA+ specifications
- Protocol specification, security checklist, incident response runbook
