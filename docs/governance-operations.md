# Governance Operations Runbook

This runbook defines how to operate StarkPrivacy governance safely using the MultiSig + Timelock pipeline.

## Components

- MultiSig: M-of-N signer approval and proposal tracking.
- Timelock: Delayed execution queue for approved actions.
- UpgradeableProxy: Upgrade gate controlled by governor (Timelock) and emergency governor.

## Recommended Production Parameters

- MultiSig threshold: 2-of-3 minimum, prefer 3-of-5+ for higher-value deployments.
- Timelock min delay: >= 24h for routine changes, >= 48h for upgrades.
- Distinct signer infrastructure: each signer uses separate device and key custody.

## Operational Workflow

1. Create proposal in MultiSig.

- Include exact target, selector, and calldata hash.
- Add human-readable rationale and rollback plan in an out-of-band ticket.

2. Collect signer approvals.

- Approvals must meet threshold before forwarding.
- Verify no signer duplication and no conflicted signers.

3. Forward approved proposal to Timelock.

- This creates a timelock operation id.
- Record operation id in change log.

4. Observe waiting period.

- Do not execute before delay expires.
- Monitor for anomalies, objections, and dependency conflicts.

5. Execute from Timelock after delay.

- Provide calldata matching the queued calldata hash.
- Verify operation is no longer pending and expected state changed.

## Change Classes

### Low-risk parameter change

Examples: fee recipient, gas factor tuning, non-critical limits.

- Standard process: MultiSig approve -> Timelock queue -> delayed execute.
- Post-checks: read-state verification and monitor health checks.

### Contract upgrade

Examples: pool logic, bridge logic, verifier wiring.

- Require extended review + simulation before forwarding.
- Validate class hash and ABI compatibility.
- Execute through Timelock-governed proxy path.
- Immediately run regression checks after execution.

### Emergency action

Examples: active exploit, severe invariants violation.

- Use emergency governor only for immediate containment.
- Typical first action: pause mutating paths.
- Follow up with documented postmortem and formal governance ratification.

## Pre-Execution Checklist

- Proposal target and selector match audited intent.
- Calldata hash matches reviewed calldata.
- Timelock operation is ready (not pending/expired/cancelled).
- Required signers are available for contingency follow-up.
- Monitoring and alerting are active.

## Post-Execution Checklist

- On-chain state reflects expected values.
- No unintended ownership/role changes.
- No critical monitor alerts fired.
- Change entry recorded with tx hash and operation id.

## Failure Handling

### Not enough approvals

- Action: collect missing signer approvals or cancel and recreate proposal.

### Timelock execution fails (calldata mismatch)

- Action: re-check encoded calldata and hash derivation, then re-queue correctly.

### Unauthorized caller errors

- Action: verify active governor/emergency-governor addresses and caller identity.

### Proposal needs to be abandoned

- Action: cancel pending timelock operation and document reason.

## Verification Commands (Examples)

Use deployed addresses from deployment manifest.

```bash
# Multisig threshold and signer count
sncast call --contract-address $MULTISIG --function get_threshold --url $STARKNET_RPC_URL
sncast call --contract-address $MULTISIG --function get_signer_count --url $STARKNET_RPC_URL

# Timelock configuration
sncast call --contract-address $TIMELOCK --function get_min_delay --url $STARKNET_RPC_URL
sncast call --contract-address $TIMELOCK --function get_proposer --url $STARKNET_RPC_URL

# Proxy governance roles
sncast call --contract-address $PROXY --function get_governor --url $STARKNET_RPC_URL
sncast call --contract-address $PROXY --function get_emergency_governor --url $STARKNET_RPC_URL
```

## Audit Trail Requirements

For each governance action, retain:

- Proposal id and timelock operation id.
- Full calldata and calldata hash.
- Approver identities and timestamps.
- Final transaction hash and state verification notes.
- Incident references if emergency path was used.

---

## Governance Flow Diagram

```
┌──────────┐     propose()     ┌──────────┐     forward()     ┌──────────┐
│          │ ────────────────> │          │ ────────────────> │          │
│ Signer 1 │                   │ MultiSig │                   │ Timelock │
│          │                   │ (M-of-N) │                   │ (delay)  │
└──────────┘                   └──────────┘                   └──────────┘
                                    ↑                              │
┌──────────┐     approve()          │                      execute() after delay
│ Signer 2 │ ──────────────────────┘                              │
└──────────┘                                                      ↓
                                                          ┌──────────────┐
                                                          │   Target     │
                                                          │  Contract    │
                                                          │ (Pool/Proxy) │
                                                          └──────────────┘
```

---

## Worked Example: Change Fee Recipient

This example walks through changing the fee recipient address on the PrivacyPool.

### 1. Prepare the Calldata

```bash
# Target: PrivacyPool
# Selector: set_fee_recipient
# Argument: new fee recipient address
TARGET=$POOL_ADDRESS
SELECTOR="set_fee_recipient"
NEW_FEE_RECIPIENT="0x04a3b8e..."

# Compute calldata hash (the Timelock validates this)
# calldata = [NEW_FEE_RECIPIENT]
echo "Calldata: $NEW_FEE_RECIPIENT"
```

### 2. Propose via MultiSig

```bash
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $SIGNER_1_ACCOUNT \
  --contract-address $MULTISIG \
  --function propose \
  --calldata $TARGET $SELECTOR $NEW_FEE_RECIPIENT
# Note the returned proposal ID (e.g., 7)
PROPOSAL_ID=7
```

### 3. Collect Approvals

```bash
# Signer 2 approves
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $SIGNER_2_ACCOUNT \
  --contract-address $MULTISIG \
  --function approve \
  --calldata $PROPOSAL_ID
```

### 4. Forward to Timelock

```bash
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $SIGNER_1_ACCOUNT \
  --contract-address $MULTISIG \
  --function forward_to_timelock \
  --calldata $PROPOSAL_ID
# Note the returned timelock operation ID
OPERATION_ID=3
```

### 5. Wait for Delay

```bash
# Check the configured delay
sncast call --contract-address $TIMELOCK --function get_min_delay --url $STARKNET_RPC_URL
# Wait for the delay to elapse (e.g., 24 hours on testnet, 48 hours on mainnet)
```

### 6. Execute

```bash
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $SIGNER_1_ACCOUNT \
  --contract-address $TIMELOCK \
  --function execute \
  --calldata $OPERATION_ID $NEW_FEE_RECIPIENT
```

### 7. Verify

```bash
sncast call --contract-address $POOL_ADDRESS --function get_fee_recipient --url $STARKNET_RPC_URL
# Should return: 0x04a3b8e...
```

---

## Pre-Execution Simulation

Before executing any governance action on mainnet, simulate it on a devnet fork:

```bash
# 1. Start a local devnet forked from mainnet state
katana --fork-url $STARKNET_RPC_URL --fork-block latest

# 2. Re-run the execute call against the fork
sncast invoke \
  --url http://localhost:5050 \
  --account $SIGNER_1_ACCOUNT \
  --contract-address $TIMELOCK \
  --function execute \
  --calldata $OPERATION_ID $CALLDATA

# 3. Verify the state change on the fork
sncast call --contract-address $TARGET --function $VIEW_FN --url http://localhost:5050

# 4. Run the monitor against the fork to check for invariant violations
STARKNET_RPC_URL=http://localhost:5050 ./scripts/monitor.sh --once
```

If the simulation succeeds, proceed with mainnet execution.

---

## Rollback Procedure

If a governance action produces unintended consequences:

### For Parameter Changes

1. **Propose a reversal** through the standard governance flow with the original value.
2. If time-critical, use the emergency governor to pause affected contracts first.
3. Wait for the timelock delay and execute the reversal.

### For Proxy Upgrades

1. **Emergency governor** can immediately upgrade the proxy to the previous class hash:
   ```bash
   sncast invoke \
     --url $STARKNET_RPC_URL \
     --account $EMERGENCY_GOVERNOR \
     --contract-address $PROXY_ADDRESS \
     --function upgrade \
     --calldata $PREVIOUS_CLASS_HASH
   ```
2. Verify the rollback restored correct behavior:
   ```bash
   starkli class-hash-at $PROXY_ADDRESS --rpc $STARKNET_RPC_URL
   # Should match $PREVIOUS_CLASS_HASH
   ```
3. Run full invariant checks before unpausing.

### For Irrecoverable Changes

Some changes (e.g., transferring ownership away from Timelock) cannot be rolled back if the new owner is uncontrolled. Always double-check ownership transfer targets.

> **Best practice**: Maintain a version log of all class hashes and parameter
> values in the deployment manifest (`scripts/deployments-*.json`) so rollback
> targets are always available.
