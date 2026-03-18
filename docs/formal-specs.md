# StarkPrivacy — Formal Verification Specifications

> Revision 1.1 — March 2026
>
> Companion to `formal-invariants.md`. Contains machine-checkable specifications
> in TLA⁺-style pseudocode for critical protocol invariants.

---

## 1. State Model

```tla
\* ─── State Variables ───────────────────────────────────────
VARIABLES
  tree,            \* Merkle tree: sequence of felt252 commitments
  next_index,      \* u64: next insert position
  root,            \* felt252: current Merkle root
  root_history,    \* sequence of length ROOT_HISTORY_SIZE
  nullifier_set,   \* set of felt252: spent nullifiers
  pool_balance,    \* function asset_id -> u256
  epoch,           \* u64: current epoch number
  epoch_nullifiers \* function epoch_num -> set of felt252

CONSTANTS
  P,               \* Field prime: 2^251 + 17*2^192 + 1
  TREE_DEPTH,      \* 32
  ROOT_HISTORY_SIZE \* 100
```

---

## 2. Value Conservation (INV-V1, INV-V2)

The core safety property: no operation creates or destroys value.

```tla
\* ─── Transfer Operation ──────────────────────────────────
Transfer(proof, root_arg, nf1, nf2, cm_out1, cm_out2) ==
  /\ root_arg \in root_history          \* Valid known root
  /\ nf1 \notin nullifier_set           \* Not already spent
  /\ nf2 \notin nullifier_set           \* Not already spent
  /\ nf1 # nf2                          \* Distinct nullifiers
  /\ VerifyProof(proof, root_arg, nf1, nf2, cm_out1, cm_out2)
  /\ LET v_in1 == ValueOf(nf1)
         v_in2 == ValueOf(nf2)
         v_out1 == ValueOf(cm_out1)
         v_out2 == ValueOf(cm_out2)
     IN  v_in1 + v_in2 = v_out1 + v_out2  \* Conservation
  /\ nullifier_set' = nullifier_set \union {nf1, nf2}
  /\ tree' = Append(Append(tree, cm_out1), cm_out2)
  /\ next_index' = next_index + 2
  /\ root' = ComputeRoot(tree')
  /\ root_history' = AddToHistory(root_history, root')
  /\ UNCHANGED <<pool_balance, epoch, epoch_nullifiers>>

\* ─── Withdraw Operation ──────────────────────────────────
Withdraw(proof, root_arg, nf1, nf2, cm_change, recipient, amount, asset) ==
  /\ root_arg \in root_history
  /\ nf1 \notin nullifier_set
  /\ nf2 \notin nullifier_set
  /\ nf1 # nf2
  /\ VerifyProof(proof, root_arg, nf1, nf2, cm_change, amount, asset)
  /\ LET v_in1 == ValueOf(nf1)
         v_in2 == ValueOf(nf2)
         v_change == ValueOf(cm_change)
     IN  v_in1 + v_in2 = v_change + amount  \* Conservation
  /\ pool_balance'[asset] = pool_balance[asset] - amount
  /\ nullifier_set' = nullifier_set \union {nf1, nf2}
  /\ tree' = Append(tree, cm_change)
  /\ next_index' = next_index + 1
  /\ root' = ComputeRoot(tree')
  /\ root_history' = AddToHistory(root_history, root')
  /\ UNCHANGED <<epoch, epoch_nullifiers>>

\* ─── Deposit Operation ───────────────────────────────────
Deposit(cm, amount, asset) ==
  /\ amount > 0
  /\ pool_balance'[asset] = pool_balance[asset] + amount
  /\ tree' = Append(tree, cm)
  /\ next_index' = next_index + 1
  /\ root' = ComputeRoot(tree')
  /\ root_history' = AddToHistory(root_history, root')
  /\ UNCHANGED <<nullifier_set, epoch, epoch_nullifiers>>
```

### Conservation Theorem

```tla
\* The sum of all unspent note values equals the pool balance
\* (across all state transitions)
PoolSolvency ==
  \A asset_id :
    SumUnspentValues(tree, nullifier_set, asset_id) = pool_balance[asset_id]

\* Proof sketch (inductive):
\* Base: Empty tree, balance = 0, sum of unspent = 0. ✓
\* Step (Deposit):   sum' = sum + amount, balance' = balance + amount. ✓
\* Step (Transfer):  sum' = sum - v_in1 - v_in2 + v_out1 + v_out2
\*                   = sum (by conservation). balance unchanged. ✓
\* Step (Withdraw):  sum' = sum - v_in1 - v_in2 + v_change
\*                   = sum - amount (by conservation).
\*                   balance' = balance - amount. ✓
```

---

## 3. Nullifier Soundness (INV-N1)

```tla
\* No nullifier can be used twice
NullifierSoundness ==
  [](
    \A nf \in nullifier_set :
      \A op \in DOMAIN(history) :
        UsesNullifier(op, nf) => op = FirstUseOf(nf)
  )

\* The on-chain check enforces this:
\* assert!(!is_nullifier_spent(nf), "nullifier already used")
\* This is a simple set-membership check that provides O(1) prevention.

\* Formal argument:
\* 1. nullifier_set starts empty
\* 2. Before adding nf, we check nf \notin nullifier_set
\* 3. After adding, nf \in nullifier_set permanently (no remove operation)
\* 4. Therefore, second use always hits the assert ∎
```

---

## 4. Merkle Tree Soundness (INV-M1, INV-M2)

```tla
\* Root consistency: the root is always the correct computation
\* over the current leaf set
RootConsistency ==
  root = MerkleRootFrom(tree, TREE_DEPTH)

\* Proof soundness: a valid proof implies leaf membership
ProofSoundness ==
  \A (R, leaf, idx, path) :
    VerifyMerklePath(R, leaf, idx, path) =>
      /\ idx < Len(tree)
      /\ tree[idx] = leaf
      /\ R \in root_history

\* Append-only: no leaf, once inserted, is ever modified
AppendOnly ==
  [](\A i \in 0..Len(tree)-1 :  tree'[i] = tree[i])
```

---

## 5. Cross-Chain Bridge Safety (INV-X1, INV-X2)

```tla
\* ─── Bridge State ────────────────────────────────────────
VARIABLES
  locked_commitments,   \* set of (commitment, dest_chain)
  synced_roots,         \* function (chain_id, epoch) -> felt252
  received_commitments  \* set of (commitment, source_chain)

\* Lock on source chain
LockForBridge(cm, dest_chain, nf1, nf2) ==
  /\ (cm, dest_chain) \notin locked_commitments  \* Replay prevention
  /\ nf1 \notin nullifier_set
  /\ nf2 \notin nullifier_set
  /\ nf1 # nf2
  /\ locked_commitments' = locked_commitments \union {(cm, dest_chain)}
  /\ nullifier_set' = nullifier_set \union {nf1, nf2}

\* Sync epoch root from source to destination
SyncEpochRoot(source_chain, epoch_num, root_val) ==
  /\ synced_roots'[source_chain, epoch_num] = root_val

\* Receive on destination chain
ReceiveFromChain(cm, source_chain, epoch_num, declared_root) ==
  /\ synced_roots[source_chain, epoch_num] = declared_root  \* Root match
  /\ (cm, source_chain) \notin received_commitments          \* Replay prevention
  /\ received_commitments' = received_commitments \union {(cm, source_chain)}

\* Safety: A commitment is received only if its epoch root was synced
BridgeSafety ==
  \A (cm, chain) \in received_commitments :
    \E epoch_num :
      synced_roots[chain, epoch_num] # 0
```

---

## 6. Epoch Manager Correctness

```tla
\* Epoch advances monotonically
EpochMonotonicity ==
  [](epoch' >= epoch)

\* Nullifiers are bound to their recording epoch
NullifierEpochBinding ==
  \A nf, e :
    nf \in epoch_nullifiers[e] =>
      /\ e <= epoch
      /\ \A e2 # e : nf \notin epoch_nullifiers[e2]

\* Epoch root is deterministic from its nullifier set
EpochRootDeterminism ==
  \A e1, e2 :
    epoch_nullifiers[e1] = epoch_nullifiers[e2] =>
      EpochRoot(e1) = EpochRoot(e2)
```

---

## 7. Liveness Properties

While safety properties (above) prevent bad things from happening, liveness
properties ensure that progress is eventually made.

```tla
\* ─── Epoch Liveness ──────────────────────────────────────
\* If the operator is live, epochs eventually advance.
EpochLiveness ==
  \* Weak fairness: if advance_epoch is continuously enabled,
  \* it is eventually taken.
  WF_vars(AdvanceEpoch) =>
    <>(epoch' > epoch)

\* ─── Deposit Liveness ────────────────────────────────────
\* A deposit that passes validation is eventually included in the tree.
DepositLiveness ==
  \A cm, amount, asset :
    /\ amount > 0
    /\ next_index < 2^TREE_DEPTH
    => <>(cm \in Range(tree))

\* ─── Withdrawal Liveness ─────────────────────────────────
\* A valid withdrawal proof is eventually processed (assuming
\* relayer liveness and sequencer liveness).
WithdrawLiveness ==
  \A proof, recipient, amount :
    /\ VerifyProof(proof, ...)
    /\ RelayerLive
    /\ SequencerLive
    => <>(BalanceOf(recipient) = BalanceOf(recipient) + amount)

\* ─── Bridge Liveness ─────────────────────────────────────
\* A locked commitment is eventually receivable on the destination
\* chain, assuming the operator syncs the epoch root.
BridgeLiveness ==
  \A (cm, dest) \in locked_commitments :
    OperatorSyncsRoot(dest) =>
      <>(cm \in Range(dest.tree))
```

> **Note**: Liveness properties depend on environmental assumptions (operator,
> relayer, sequencer availability). They are useful for reasoning about
> protocol completeness but cannot be enforced on-chain alone.

---

## 8. Fee Model Specification

```tla
\* ─── Fee Constants ───────────────────────────────────────
CONSTANTS
  MAX_FEE,            \* Maximum fee in felt252 (protocol parameter)
  PROTOCOL_FEE_BPS,   \* Basis points for protocol fee (e.g., 10 = 0.1%)
  MAX_GAS_FACTOR      \* Maximum gas price factor in BPS (1,000,000 = 100x)

\* ─── Fee Computation (EVM path) ──────────────────────────
EstimateEvmFee(amount, gas) ==
  LET protocol_fee == (amount * PROTOCOL_FEE_BPS) \div 10000
      gas_premium  == (gas * gas_price_factor) \div 10000
  IN  (protocol_fee, gas_premium, protocol_fee + gas_premium)

\* ─── Fee Invariants ──────────────────────────────────────
\* INV-F1: Total fee never exceeds MAX_FEE
FeeBound ==
  \A transfer :
    transfer.fee <= MAX_FEE

\* INV-F2: Fee is included in the conservation equation
FeeConservation ==
  \A transfer :
    transfer.v_in1 + transfer.v_in2 =
      transfer.v_out1 + transfer.v_out2 + transfer.fee

\* INV-F3: Gas price factor stays within bounds
GasFactorBound ==
  [](gas_price_factor > 0 /\ gas_price_factor <= MAX_GAS_FACTOR)

\* INV-F4: Fee estimation is a pure function (no state dependency)
FeeEstimationPurity ==
  \A s1, s2 :  \* For any two states
    EstimateEvmFee(s1, amount, gas) = EstimateEvmFee(s2, amount, gas)
```

---

## 9. Access Control Model

```tla
\* Only owner can call admin functions
OwnerExclusivity ==
  \A op \in AdminOperations :
    op.caller # owner => op.result = REVERT

\* Timelock enforces minimum delay
TimelockDelay ==
  \A op \in TimelockOperations :
    op.executed_at < op.scheduled_at + op.delay => op.result = REVERT

\* MultiSig requires threshold
MultiSigThreshold ==
  \A prop \in Proposals :
    Cardinality(prop.approvals) < threshold =>
      prop.executed = FALSE
```

---

## 10. Kakarot Adapter Safety

```tla
\* Adapter is a pure proxy — all state changes flow through the underlying pool
KakarotProxy ==
  \A op \in {evm_deposit, evm_transfer, evm_withdraw} :
    /\ ~paused                           \* Not paused
    /\ PoolStateAfter(op) = DirectPoolStateAfter(op)  \* Same result as direct call

\* Pause blocks all mutating operations but not views
PauseSemantics ==
  paused =>
    /\ evm_deposit  => REVERT
    /\ evm_transfer => REVERT
    /\ evm_withdraw => REVERT
    /\ get_root     => OK \* Views still work
    /\ get_leaf_count => OK

\* Fee estimation is stateless and deterministic
FeeEstimationPure ==
  \A (amount, gas, factor) :
    estimate_evm_fee(amount, gas) =
      LET protocol_fee == (amount * 10) \div 10000
          gas_premium  == (gas * factor) \div 10000
      IN  (protocol_fee, gas_premium, protocol_fee + gas_premium)
```

---

## 11. Verification Approach

### Tools

| Property            | Approach                | Tool              | Status    |
| ------------------- | ----------------------- | ----------------- | --------- |
| Value Conservation  | Inductive invariant     | TLA⁺ / Lean 4     | Specified |
| Nullifier Soundness | Set-based reasoning     | TLA⁺              | Specified |
| Merkle Soundness    | Hash function model     | Lean 4            | Specified |
| Bridge Safety       | State machine model     | TLA⁺              | Specified |
| Access Control      | Permission model        | Manual audit      | Specified |
| Fee Estimation      | Arithmetic verification | Fuzz tests (done) | Verified  |
| Liveness            | Temporal logic (WF/SF)  | TLA⁺              | Specified |
| Fee Model           | Arithmetic + bounds     | TLA⁺              | Specified |

### Verification Roadmap

1. **Phase 1** (Current): TLA⁺-style specifications with proof sketches
2. **Phase 2**: Mechanize in Lean 4 / Coq for critical properties (V1, V2, N1)
3. **Phase 3**: Apply Blockchain-specific tools (Certora / Halmos) if Starknet support matures
4. **Phase 4**: Formal link between specifications and Cairo bytecode (STARK verifier)

### Coverage vs. formal-invariants.md

| Invariant | Specified | Proof Sketch                        | Mechanized |
| --------- | --------- | ----------------------------------- | ---------- |
| INV-C1    | ✅        | ✅ (collision-resistance reduction) | ⬜         |
| INV-C2    | ✅        | ✅ (preimage-resistance reduction)  | ⬜         |
| INV-C3    | ✅        | ✅ (determinism of Poseidon)        | ⬜         |
| INV-N1    | ✅        | ✅ (set-based inductive)            | ⬜         |
| INV-N2–N5 | ✅        | ✅ (domain-sep argument)            | ⬜         |
| INV-M1    | ✅        | ✅ (recursive hash definition)      | ⬜         |
| INV-M2    | ✅        | ✅ (path verification)              | ⬜         |
| INV-M3    | ✅        | ✅ (append-only by design)          | ⬜         |
| INV-V1    | ✅        | ✅ (inductive over operations)      | ⬜         |
| INV-V2    | ✅        | ✅ (inductive over operations)      | ⬜         |
| INV-V3    | ✅        | ✅ (inductive solvency)             | ⬜         |
| INV-X1    | ✅        | ✅ (root match check)               | ⬜         |
| INV-X2    | ✅        | ✅ (set replay prevention)          | ⬜         |
| INV-A1–A6 | ✅        | ✅ (caller-check model)             | ⬜         |
| INV-RE1   | ✅        | ✅ (boolean lock)                   | ⬜         |
| INV-F1–F4 | ✅        | ✅ (arithmetic bounds)              | ⬜         |
