# StarkPrivacy Security Audit Checklist

> Pre-audit self-assessment — June 2025

## Legend

- [x] Addressed in code
- [ ] Requires external review / future work

---

## 1. Cryptographic Correctness

- [x] Poseidon hash used consistently (no mixing Poseidon + Pedersen for same purpose)
- [x] Nullifier includes spending key + commitment + domain separation (chain_id, app_id)
- [x] Blinding factor sampled from secure random source (`randomFelt252`)
- [x] Note commitment binds all note fields (value, asset_id, owner_hash, blinding)
- [ ] Formal verification of Poseidon instantiation against reference specification
- [ ] Independent audit of nullifier scheme for binding/hiding properties

## 2. Merkle Tree

- [x] Depth-32 tree supports ~4B leaves
- [x] Zero hashes computed deterministically, matching on-chain and off-chain
- [x] Root history ring buffer (100 entries) prevents stale-root DoS
- [x] Leaf index bounds checking in proof generation
- [ ] Fuzz testing for tree insert/verify edge cases at boundary indices

## 3. Circuit Constraints

- [x] Transfer circuit enforces value conservation ($\Sigma in = \Sigma out + fee$)
- [x] Withdraw circuit enforces exit_value + change = input sum - fee
- [x] Both circuits verify Merkle proofs against declared root
- [x] Commitment recomputation matches on-chain formula
- [x] Transfer circuit enforces asset_id consistency across inputs and outputs
- [x] Formal constraint count audit (verify no under-constrained variables)
  - Transfer: 8 constraint groups (commitment, nullifier, dup-nullifier, Merkle, output commitment, range, balance, asset, owner)
  - Withdraw: 8 constraint groups (commitment, nullifier, dup-nullifier, Merkle, change commitment, range, balance, asset, owner)
  - **Fixed**: Transfer circuit was missing asset_id consistency check (inputs/outputs could mix asset types)
  - **Remaining**: fee not range-checked against MAX_NOTE_VALUE (low severity — u128 bound is sufficient)
- [x] STARK soundness parameter review (see protocol-spec.md §9.4)
  - Parameters delegated to external prover (stone-prover / S-Two)
  - Minimum requirements documented: 128-bit security, FRI blowup ≥4, ≥3 FRI queries
  - Application layer validates proof envelope structure only (size, type field)
  - **Action required before mainnet**: verify deployed prover meets documented minimums

## 4. Smart Contract Security

### 4.1 Access Control

- [x] Owner-only functions use `assert(caller == owner)` pattern
- [x] EpochManager / BridgeRouter restrict `advance_epoch` / `publish_epoch_root` to owner
- [x] MadaraAdapter `register_peer` / `sync_epoch_root` restricted to owner
- [x] KakarotAdapter `pause` / `unpause` / `set_gas_price_factor` restricted to owner
- [ ] Consider role-based access (separate operator vs. admin roles)

### 4.2 Reentrancy

- [x] `ReentrancyGuard` component implemented (lock/unlock around external calls)
- [x] Withdraw follows checks-effects-interactions pattern
- [ ] Verify all external call sites are guarded

### 4.3 Denial of Service

- [x] `RateLimiter` component: per-address, per-operation rate limits
- [x] Configurable limits (max operations per window)
- [ ] Rate limiter window reset mechanism audited for clock manipulation

### 4.4 Integer / Felt Overflow

- [x] All arithmetic within $\mathbb{F}_p$; no integer overflow possible
- [x] Value assertions (non-zero amounts, positive values)
- [ ] Review for unintended felt252 wrap-around in edge cases

### 4.5 Nullifier Handling

- [x] Double-spend prevention: `is_spent` checked before processing
- [x] Nullifier marked spent atomically with state update
- [x] Domain-separated nullifiers prevent cross-chain replay
- [x] Duplicate nullifier pairs rejected in transfer/lock operations

## 5. Cross-Chain Security

### 5.1 L1 Bridge

- [x] Uses `send_message_to_l1_syscall` (Starknet native messaging)
- [x] L1 recipient validated (non-zero)
- [x] Amount validation on deposit/withdraw
- [ ] L1 contract counterpart audit (Solidity side)

### 5.2 Madara Appchain

- [x] Self-peering rejected (`cannot peer with self`)
- [x] Duplicate peer registration rejected
- [x] Epoch root verified before accepting inbound commitments
- [x] Commitment replay prevention (`processed_commitments` map)
- [x] Cross-chain message ordering guarantees reviewed (see protocol-spec.md §9.2)
- [x] Relayer trust assumptions documented and tested (see protocol-spec.md §9.1)

### 5.3 Kakarot EVM Bridge

- [x] KakarotAdapter routes EVM calls to underlying PrivacyPool (pure proxy)
- [x] Emergency pause mechanism blocks all mutating EVM operations
- [x] View functions accessible even when paused
- [x] Gas price factor bounded (must be > 0 and ≤ 1,000,000 BPS / 100x cap, admin-configurable)
- [x] Fee estimation is stateless and deterministic (no state dependency)
- [x] Double-pause and double-unpause rejected
- [x] Pause/unpause emit events for monitoring (AdapterPaused / AdapterUnpaused)
- [x] 15 cross-chain integration tests cover adapter + pool interaction
- [x] Kakarot address translation security review
  - Adapter accepts felt252 directly; EVM→Cairo translation is handled by Kakarot at the boundary
  - No custom address mapping logic — adapter is a pure proxy to the pool
  - No truncation or overflow risk since felt252 is the native type
- [x] EVM gas griefing analysis (malicious gas parameter manipulation)
  - `gas_price_factor` capped at MAX_GAS_PRICE_FACTOR (1,000,000 BPS = 100x)
  - `estimate_evm_fee` is view-only; actual fees are encoded in ZK proof public inputs
  - A compromised admin can only affect fee UX estimates, not actual on-chain fee enforcement
  - Pause mechanism provides emergency shutdown if gas factor is manipulated

## 6. Privacy Properties

### 6.1 Transaction Privacy

- [x] Note values never appear in public inputs
- [x] Spending keys never appear in public inputs
- [x] Only nullifiers and commitments published on-chain
- [x] Information-theoretic analysis of nullifier leakage (see protocol-spec.md §9.3.1)

### 6.2 Metadata Resistance

- [x] Fixed-size 64-felt envelopes (no payload length leakage)
- [x] Dummy envelope padding in batches
- [x] Relay jitter (uniform random delay before submission)
- [x] Traffic analysis resistance under realistic network model (see protocol-spec.md §9.3.2)

### 6.3 Stealth Addresses

- [x] Ephemeral key generated per transaction
- [x] Shared secret derived via Poseidon (not plain DH)
- [x] Scan tag per-epoch (limits scanning window)
- [x] Note payload encrypted with shared secret
- [x] Key leakage impact analysis (see protocol-spec.md §9.3.3)

## 7. SDK Security

- [x] No private keys stored in plaintext (managed by KeyManager)
- [x] Spending key derived from seed via Poseidon hash
- [x] Viewing key separate from spending key
- [x] Coin selection avoids unnecessary linking (greedy by value)
- [ ] Side-channel analysis of client-side proof generation
- [ ] Secure memory handling for key material (memzero)

## 8. Compliance

- [x] Optional sanctions oracle hook (`is_allowed` before deposit)
- [x] Oracle interface allows diverse compliance strategies
- [x] Non-blocking for transfers/withdrawals (only deposit-time check)
- [ ] Regulatory review of compliance model
- [ ] Selective disclosure mechanism for auditors

## 9. Operational Security

- [x] CI pipeline runs all tests on every push
- [x] Build reproducibility via pinned scarb + starknet versions
- [x] Deployment scripts validate deployed bytecode
- [x] Multi-sig / timelock on contract upgrades (Phase D governance wiring)
- [x] Pool health monitoring script (`scripts/monitor.sh`) with automated alerts
- [x] Incident response runbook with severity levels and playbooks (`docs/incident-response.md`)
- [x] CD staging workflow for automated deploy-to-sepolia
- [ ] Bug bounty program
- [x] Production key rotation procedure

## 10. Testing Coverage

| Component                                  | Tests    | Status         |
| ------------------------------------------ | -------- | -------------- |
| Primitives (hash, commitment, nullifier)   | 13       | ✅             |
| Merkle tree                                | 10       | ✅             |
| Circuits (transfer, withdraw, verifier)    | 18       | ✅             |
| Privacy pool                               | 11       | ✅             |
| Stealth (registry, encrypted notes)        | 16       | ✅             |
| Bridge (router, L1, epoch, Madara)         | 23       | ✅             |
| KakarotAdapter (EVM bridge)                | 15       | ✅             |
| Compliance                                 | 10       | ✅             |
| Security components                        | 5        | ✅             |
| Governance (timelock, multisig, wiring)    | 25       | ✅             |
| Fuzz / property-based (×256 each)          | 15       | ✅             |
| SDK (crypto, keys, notes, prover, relayer) | 154      | ✅             |
| SDK indexer (mock-based)                   | 19       | ✅             |
| **Total**                                  | **334+** | **0 failures** |

- [x] Property-based / fuzz testing (15 fuzz tests × 256 runs each)
- [x] Formal verification specifications with proof sketches (`docs/formal-specs.md`)
- [ ] Mechanized formal proofs (Lean 4 / Coq)
- [ ] Mainnet dry-run with production parameters

---

## Summary

**Critical items requiring external audit:**

1. STARK circuit soundness and constraint completeness
2. Poseidon instantiation correctness
3. Cross-chain message integrity (L1 ↔ L2 ↔ Madara ↔ Kakarot EVM)
4. Nullifier scheme binding/hiding proofs
5. Privacy guarantees under adversarial network model
6. Kakarot EVM address translation and gas griefing vectors
