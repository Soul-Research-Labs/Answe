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
