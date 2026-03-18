# StarkPrivacy Formal Invariants & Verification Spec

> Revision 1.1 — March 2026

This document defines the formal invariants that must hold for correctness
of the StarkPrivacy protocol. These are the properties that a formal
verification effort should target.

---

## 1. Commitment Scheme Invariants

### INV-C1: Commitment Binding

For any two distinct notes $N_1 \neq N_2$ (differing in at least one field):

$$\text{commit}(N_1) \neq \text{commit}(N_2) \quad \text{(with overwhelming probability)}$$

**Verified by**: Fuzz tests `test_fuzz_commitment_blinding_independence`,
`test_fuzz_commitment_owner_binding`

### INV-C2: Commitment Hiding

Given only $C = \text{commit}(N)$, no PPT adversary can recover
$(owner, value, asset\_id, blinding)$ with non-negligible advantage.

**Relies on**: Poseidon preimage resistance

### INV-C3: Commitment Determinism

$$\forall N: \text{commit}(N) = \text{commit}(N) \quad \text{(pure function)}$$

**Verified by**: Fuzz test `test_fuzz_commitment_deterministic` (256 runs)

---

## 2. Nullifier Scheme Invariants

### INV-N1: Nullifier Uniqueness (No Double-Spend)

For any note commitment $C$, spending key $sk$, and domain $(chain, app)$:

$$\text{nullifier}(sk, C, chain, app) \text{ is unique per } (sk, C, chain, app)$$

**Verified by**: On-chain `is_nullifier_spent` check + fuzz test
`test_fuzz_nullifier_deterministic`

### INV-N2: Nullifier Domain Separation

$$\forall sk, C, chain_1 \neq chain_2: \text{nf}(sk, C, chain_1, app) \neq \text{nf}(sk, C, chain_2, app)$$

**Verified by**: Fuzz test `test_fuzz_nullifier_chain_separation` (256 runs)

### INV-N3: Nullifier Key Binding

$$\forall sk_1 \neq sk_2, C: \text{nf}(sk_1, C, chain, app) \neq \text{nf}(sk_2, C, chain, app)$$

Only the note owner (who knows $sk$) can produce the correct nullifier.

**Verified by**: Fuzz test `test_fuzz_nullifier_key_binding` (256 runs)

### INV-N4: Nullifier Commitment Binding

$$\forall sk, C_1 \neq C_2: \text{nf}(sk, C_1, chain, app) \neq \text{nf}(sk, C_2, chain, app)$$

**Verified by**: Fuzz test `test_fuzz_nullifier_commitment_binding` (256 runs)

### INV-N5: Nullifier App Separation

$$\forall sk, C, chain, app_1 \neq app_2: \text{nf}(sk, C, chain, app_1) \neq \text{nf}(sk, C, chain, app_2)$$

Different application identifiers produce distinct nullifiers, preventing cross-app double-spend.

**Verified by**: Fuzz test `test_fuzz_nullifier_app_separation` (256 runs)

---

## 3. Merkle Tree Invariants

### INV-M1: Root Consistency

After inserting commitment $C$ at index $i$, the root $R'$ must be the
unique value satisfying:

$$R' = \text{recompute}(C, i, \text{siblings})$$

### INV-M2: Proof Soundness

$$\text{verify}(R, C, i, \text{path}) = \text{true} \implies C \text{ is the leaf at index } i \text{ in tree with root } R$$

**Verified by**: `test_verify_merkle_proof_valid`, `test_verify_merkle_proof_invalid_leaf`

### INV-M3: Append-Only

Once a leaf is inserted at index $i$, it cannot be modified:

$$\forall j < \text{next\_index}: \text{leaves}[j] \text{ is immutable}$$

**Enforced by**: Contract logic (no `update_leaf` function exists)

### INV-M4: Root History

The pool maintains `ROOT_HISTORY_SIZE = 100` recent roots. A proof is valid
if its root appears in this ring buffer:

$$\text{is\_known\_root}(R) \implies \exists k \in [0, 100): \text{root\_history}[k] = R$$

---

## 4. Value Conservation Invariants

### INV-V1: Transfer Conservation

For a valid 2-in-2-out transfer:

$$v_{in_0} + v_{in_1} = v_{out_0} + v_{out_1} + \text{fee}$$

**Verified by**: `TransferCircuit` constraint, `test_transfer_value_conservation`

### INV-V2: Withdraw Conservation

For a valid withdrawal:

$$v_{in_0} + v_{in_1} = v_{change} + v_{exit} + \text{fee}$$

**Verified by**: `WithdrawCircuit` constraint

### INV-V3: Pool Solvency

At all times, the total value of unspent notes in the tree equals the
pool's escrowed balance:

$$\sum_{i : \text{unspent}(i)} v_i = \text{pool\_balance}$$

---

## 5. Access Control Invariants

### INV-A1: Owner Exclusivity

Admin functions (epoch advance, peer registration, oracle updates) can
only be called by the designated `owner` address:

$$\text{caller} \neq \text{owner} \implies \text{revert}$$

### INV-A2: Timelock Delay

No timelocked operation can execute before its delay has elapsed:

$$\text{execute}(op) \text{ succeeds} \implies \text{now} \geq \text{timestamp}(op) + \text{delay}(op)$$

**Verified by**: `test_timelock_execute_too_early_rejected`

### INV-A3: MultiSig Threshold

An operation is approved only when the approval count meets or exceeds threshold:

$$\text{is\_approved}(op) \iff \text{approvals}(op) \geq \text{threshold}$$

**Verified by**: `test_multisig_reaches_threshold`, `test_multisig_three_of_three`

### INV-A4: Timelock Calldata Integrity

The `execute` function succeeds only when the provided calldata hashes to the stored calldata hash:

$$\text{execute}(op, \text{calldata}) \text{ succeeds} \implies \text{poseidon\_hash\_span}(\text{calldata}) = \text{stored\_calldata\_hash}(op)$$

**Verified by**: `test_execute_calldata_mismatch_reverts`, `test_full_governance_flow`

### INV-A5: MultiSig→Timelock Forward

A proposal can only be forwarded to timelock after reaching threshold and before execution:

$$\text{forward\_to\_timelock}(prop) \text{ succeeds} \implies \text{approvals}(prop) \geq \text{threshold} \wedge \neg\text{executed}(prop) \wedge \text{timelock} \neq 0$$

**Verified by**: `test_forward_to_timelock`, `test_forward_insufficient_reverts`, `test_forward_without_timelock_reverts`

### INV-A6: Timelock Cross-Contract Execution

On successful execution, the timelock makes an actual cross-contract call with the verified calldata:

$$\text{execute}(op, \text{calldata}) \text{ succeeds} \implies \text{call\_contract\_syscall}(\text{target}(op), \text{selector}(op), \text{calldata})$$

**Verified by**: `test_full_governance_flow` (end-to-end MultiSig→Timelock→target)

---

## 6. Cross-Chain Invariants

### INV-X1: Epoch Root Integrity

A cross-chain receive is valid only if the declared epoch root matches
the synced root:

$$\text{receive}(C, chain, epoch, R) \text{ succeeds} \implies \text{synced\_root}(chain, epoch) = R$$

**Verified by**: `test_receive_wrong_epoch_root_rejected`

### INV-X2: Commitment Replay Prevention

No commitment can be received more than once on the same chain:

$$\text{processed}(C) = \text{true} \implies \text{receive}(C, \ldots) \text{ reverts}$$

**Verified by**: `test_lock_same_commitment_twice_rejected`

### INV-X3: Self-Peering Prevention

An adapter cannot register itself as a peer:

$$\text{register\_peer}(\text{self.chain\_id}, \ldots) \text{ reverts}$$

**Verified by**: `test_register_self_rejected`

---

## 7. Rate Limiting Invariants

### INV-R1: Window Enforcement

Within a single time window, no address can exceed `max_ops_per_window`:

$$\forall addr, t \in [\text{window\_start}, \text{window\_start} + \text{duration}):\\ \text{ops}(addr, t) \leq \text{max\_ops}$$

### INV-R2: Window Reset

When the window expires, the counter resets:

$$t \geq \text{window\_start} + \text{duration} \implies \text{ops\_count} \text{ resets to } 1$$

---

## 8. Stealth Address Invariants

### INV-S1: Scanning Correctness

If a note was sent to a stealth address derived from meta-address $(S, V)$,
the recipient holding viewing key $v$ can identify it via scan tag matching:

$$\text{scan}(v, R) = \text{true} \iff \text{sent\_to\_meta}(S, V, R)$$

### INV-S2: Unlinkability

No observer without $v$ can determine whether two stealth addresses belong
to the same recipient.

---

## 9. Reentrancy Safety

### INV-RE1: Lock Exclusion

At most one protected code section can be active at any time:

$$\text{start}() \text{ while } \text{locked} = \text{true} \implies \text{revert}$$

**Enforced by**: `ReentrancyGuard` component

---

## 10. Fee Invariants

### INV-F1: Fee Bound

The fee charged on any transfer or withdrawal never exceeds the protocol maximum:

$$\text{fee} \leq \text{MAX\_FEE}$$

**Verified by**: Circuit constraint (fee is a public input verified by the proof).

### INV-F2: Fee Conservation

Fees are accounted for in the value conservation equation — they do not create or destroy value:

$$v_{in_0} + v_{in_1} = v_{out_0} + v_{out_1} + \text{fee}$$

**Verified by**: `test_transfer_value_conservation`, formal spec §8 in `formal-specs.md`.

### INV-F3: Gas Price Factor Bound (Kakarot)

The EVM gas price factor is always positive and never exceeds MAX_GAS_PRICE_FACTOR:

$$0 < \text{gas\_price\_factor} \leq 1{,}000{,}000 \text{ BPS}$$

**Verified by**: `test_set_gas_price_factor_zero_reverts`, `test_set_gas_price_factor_exceeds_max_reverts`.

---

## 11. Pause Semantics Invariants

### INV-P1: Pause Blocks Mutations

When a contract is paused, all mutating operations (deposit, transfer, withdraw, lock) must revert:

$$\text{paused} = \text{true} \implies \forall \text{mutating\_op}: \text{revert}$$

**Verified by**: `test_evm_deposit_while_paused_reverts`, `test_evm_transfer_while_paused_reverts`, `test_evm_withdraw_while_paused_reverts`.

### INV-P2: Pause Preserves Views

When paused, read-only (view) functions remain accessible:

$$\text{paused} = \text{true} \implies \text{get\_root(), get\_leaf\_count()} \text{ succeed}$$

**Verified by**: `test_view_functions_work_when_paused`.

---

## 12. Upgrade Safety Invariants

### INV-U1: Storage Layout Preservation

A proxy upgrade must not alter the storage layout of existing state variables. New variables may only be appended:

$$\forall i < |\text{slots}_{\text{old}}|: \text{slot}_i^{\text{new}} = \text{slot}_i^{\text{old}}$$

**Verified by**: Manual review during upgrade approval; class hash validation in deployment scripts.

### INV-U2: Governance-Gated Upgrades

Contract upgrades can only be executed through the governance pipeline (MultiSig → Timelock → Proxy):

$$\text{upgrade}(\text{new\_class\_hash}) \text{ succeeds} \implies \text{caller} = \text{governor} \lor \text{caller} = \text{emergency\_governor}$$

**Verified by**: `test_full_governance_flow`, proxy access control tests.

---

## 13. Verification Status

| Invariant | Fuzz     | Unit | Formal | Status                 |
| --------- | -------- | ---- | ------ | ---------------------- |
| INV-C1    | ✅ (256) | ✅   | 📝     | Tested + spec'd        |
| INV-C2    | —        | —    | 📝     | Spec'd (Poseidon)      |
| INV-C3    | ✅ (256) | ✅   | 📝     | Tested + spec'd        |
| INV-N1    | ✅ (256) | ✅   | 📝     | Tested + proof sketch  |
| INV-N2    | ✅ (256) | ✅   | 📝     | Tested + spec'd        |
| INV-N3    | ✅ (256) | ✅   | 📝     | Tested + spec'd        |
| INV-N4    | ✅ (256) | ✅   | 📝     | Tested + spec'd        |
| INV-M1    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-M2    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-M3    | —        | ✅   | 📝     | By design + spec'd     |
| INV-M4    | —        | ✅   | ⬜     | Tested                 |
| INV-V1    | —        | ✅   | 📝     | Tested + proof sketch  |
| INV-V2    | —        | ✅   | 📝     | Tested + proof sketch  |
| INV-V3    | —        | —    | 📝     | Inductive proof sketch |
| INV-A1    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-A2    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-A3    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-A4    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-A5    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-A6    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-N5    | ✅ (256) | ✅   | 📝     | Tested + spec'd        |
| INV-X1    | —        | ✅   | 📝     | Tested + proof sketch  |
| INV-X2    | —        | ✅   | 📝     | Tested + proof sketch  |
| INV-X3    | —        | ✅   | ⬜     | Tested                 |
| INV-R1    | —        | ✅   | ⬜     | Tested                 |
| INV-R2    | —        | ✅   | ⬜     | Tested                 |
| INV-S1    | —        | ✅   | ⬜     | Tested                 |
| INV-S2    | —        | —    | ⬜     | Assumed (ECDH)         |
| INV-RE1   | —        | ✅   | 📝     | Tested + spec'd        |
| INV-F1    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-F2    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-F3    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-P1    | —        | ✅   | 📝     | Tested + spec'd        |
| INV-P2    | —        | ✅   | ⬜     | Tested                 |
| INV-U1    | —        | —    | ⬜     | Manual review          |
| INV-U2    | —        | ✅   | 📝     | Tested + spec'd        |

**Legend**: ✅ = Verified, 📝 = Formal spec + proof sketch (see `formal-specs.md`), ⬜ = Pending

---

## 14. Recommended Formal Verification Targets

Priority 1 (critical):

1. **INV-V1 / INV-V2**: Value conservation — proves no inflation/deflation
2. **INV-N1**: Nullifier uniqueness — proves no double-spend
3. **INV-M2**: Merkle proof soundness — proves membership correctness

Priority 2 (high): 4. **INV-V3**: Pool solvency — inductive proof over all state transitions 5. **INV-X1**: Cross-chain root integrity

Priority 3 (desirable): 6. **INV-C2**: Commitment hiding (reduction to Poseidon security) 7. **INV-S2**: Stealth unlinkability (reduction to ECDH)
