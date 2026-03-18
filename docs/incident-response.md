# StarkPrivacy — Incident Response Runbook

## Table of Contents

1. [Severity Levels](#severity-levels)
2. [Incident Detection](#incident-detection)
3. [Response Procedures](#response-procedures)
4. [Scenario Playbooks](#scenario-playbooks)
5. [Key Rotation Procedures](#key-rotation-procedures)
6. [Communication Templates](#communication-templates)
7. [Post-Incident Checklist](#post-incident-checklist)

---

## Severity Levels

| Level | Name     | Description                          | Response Time | Escalation               |
| ----- | -------- | ------------------------------------ | ------------- | ------------------------ |
| P0    | Critical | Funds at risk, active exploit        | Immediate     | All on-call + leadership |
| P1    | High     | Protocol degraded, potential exploit | < 15 min      | On-call + security lead  |
| P2    | Medium   | Feature broken, no funds at risk     | < 1 hour      | On-call engineer         |
| P3    | Low      | Cosmetic, monitoring noise           | < 24 hours    | Next business day        |

---

## Incident Detection

### Automated Alerts (from `scripts/monitor.sh`)

| Alert                                              | Severity | Meaning                                                  |
| -------------------------------------------------- | -------- | -------------------------------------------------------- |
| `CRITICAL: Leaf count DECREASED`                   | P0       | Merkle tree state corruption — possible reorg or exploit |
| `CRITICAL: Merkle root is zero but leaf count > 0` | P0       | Tree integrity failure                                   |
| `CRITICAL: RPC node unreachable`                   | P1       | Infrastructure outage                                    |
| `CRITICAL: Epoch DECREASED`                        | P0       | Possible chain rollback or state tampering               |
| `WARNING: Epoch stalled`                           | P2       | Epoch manager not advancing — check operator             |
| `WARNING: Kakarot adapter PAUSED`                  | P2       | EVM bridge halted (may be intentional)                   |
| `ABNORMAL GROWTH: >100 deposits`                   | P1       | Possible spam attack or exploit loop                     |

### Manual Detection

- **User reports**: Unable to withdraw, stuck transactions
- **Block explorer**: Unexpected contract state changes
- **Auditor notification**: Vulnerability disclosure

---

## Response Procedures

### Step 0: Triage (All Incidents)

1. **Acknowledge** the alert in the communication channel
2. **Assess severity** using the table above
3. **Open an incident channel** (e.g., `#incident-YYYY-MM-DD` in Slack)
4. **Assign incident commander** (IC) — the first responder owns coordination

### Step 1: Contain (P0/P1)

Execute emergency pause if funds are at risk:

```bash
# Pause the Kakarot adapter (blocks EVM operations)
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $ADMIN_ACCOUNT \
  --contract-address $KAKAROT_ADAPTER_ADDRESS \
  --function pause

# Pause the bridge router (blocks cross-chain locks)
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $ADMIN_ACCOUNT \
  --contract-address $BRIDGE_ROUTER_ADDRESS \
  --function pause_bridge
```

For the privacy pool (if the pool has an emergency pause):

```bash
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $ADMIN_ACCOUNT \
  --contract-address $POOL_ADDRESS \
  --function emergency_pause
```

### Step 2: Preserve Evidence

Before making any state changes, capture a forensic snapshot:

```bash
# Snapshot current block number
BLOCK=$(starkli block-number --rpc $STARKNET_RPC_URL)
echo "Forensic snapshot at block: $BLOCK" >> incident.log

# Export all pool events from suspect block range
starkli events --from-block $((BLOCK - 100)) --to-block $BLOCK \
  --contract $POOL_ADDRESS \
  --rpc $STARKNET_RPC_URL > forensic-events-$BLOCK.json

# Export current contract state
for CONTRACT in $POOL_ADDRESS $BRIDGE_ROUTER_ADDRESS $EPOCH_MANAGER_ADDRESS $KAKAROT_ADAPTER_ADDRESS; do
  starkli call $CONTRACT get_root --rpc $STARKNET_RPC_URL >> state-snapshot-$BLOCK.log 2>&1 || true
done

# Preserve relayer job queue
cp relayer-jobs.db "relayer-jobs-$BLOCK.db.bak" 2>/dev/null || true
```

> **Important**: Never overwrite forensic evidence. Use timestamped or block-numbered filenames.

### Step 3: Investigate

1. **Collect evidence**:

   ```bash
   # Export recent events
   starkli events --from-block $SUSPECT_BLOCK \
     --contract $POOL_ADDRESS \
     --rpc $STARKNET_RPC_URL > events.json

   # Check nullifier state
   starkli call $POOL_ADDRESS is_nullifier_spent $NULLIFIER_HASH \
     --rpc $STARKNET_RPC_URL

   # Check Merkle root history
   starkli call $POOL_ADDRESS is_known_root $SUSPECT_ROOT \
     --rpc $STARKNET_RPC_URL
   ```

2. **Identify the root cause**:
   - Check transaction traces for unexpected state changes
   - Compare on-chain state with expected invariants (see `docs/formal-invariants.md`)
   - Review recent deployments or upgrades

3. **Document timeline** in the incident channel

### Step 4: Remediate

- **If exploit**: Deploy patch, upgrade proxy (see J3), unpause
- **If infrastructure**: Restore RPC, check block production, verify state
- **If false alarm**: Retune monitoring thresholds, update runbook

### Step 5: Recover

1. Verify all invariants hold (run `scripts/monitor.sh --once`)
2. Unpause contracts in reverse order (pool → bridge → Kakarot)
3. Verify a test transaction works end-to-end
4. Announce recovery to users

---

## Scenario Playbooks

### Scenario A: Double-Spend Attempt Detected

**Trigger**: Nullifier already spent error in logs, or nullifier count anomaly.

1. **Pause** pool immediately (Step 1)
2. Query the nullifier registry:
   ```bash
   starkli call $POOL_ADDRESS is_nullifier_spent $NULLIFIER \
     --rpc $STARKNET_RPC_URL
   ```
3. If the nullifier IS spent and a second transaction succeeded → **P0 exploit**
4. If the transaction reverted → monitoring false positive, no action needed
5. Cross-reference with `docs/formal-invariants.md` invariants N1–N4

### Scenario B: Merkle Tree Corruption

**Trigger**: Root is zero with non-zero leaf count, or leaf count decreased.

1. **Pause** all contracts (Step 1)
2. Reconstruct expected tree state from events:
   ```bash
   # Scan all deposit events from genesis
   starkli events --from-block 0 \
     --contract $POOL_ADDRESS \
     --keys 0x9149d2123147c5f43d258257fef0b7b969db78269369ebcf5c3f201e16f2b \
     --rpc $STARKNET_RPC_URL > deposits.json
   ```
3. Compare on-chain root with expected root computed from deposit events
4. If mismatch → check for unauthorized `insert` calls or proxy upgrade attacks

### Scenario C: Bridge Epoch Desync

**Trigger**: Epoch root mismatch between chains, receive_from_appchain failing.

1. Compare epoch roots on both chains:
   ```bash
   # Source chain
   starkli call $EPOCH_MGR_SRC get_epoch_root $EPOCH_NUM --rpc $RPC_SRC
   # Destination chain
   starkli call $MADARA_ADAPTER_DST get_peer_epoch_root $SRC_CHAIN_ID $EPOCH_NUM --rpc $RPC_DST
   ```
2. If roots differ → re-sync the correct root from the source chain
3. Check that the epoch manager operator is running and advancing epochs

### Scenario D: Kakarot Adapter Exploit

**Trigger**: Unexpected EVM operations, gas price factor manipulation.

1. **Pause** Kakarot adapter immediately
2. Check gas price factor:
   ```bash
   starkli call $KAKAROT_ADDRESS get_gas_price_factor --rpc $STARKNET_RPC_URL
   ```
3. If factor was changed by unauthorized party → ownership compromise
4. Review `GasPriceFactorUpdated` events for unauthorized changes
5. If ownership is compromised → rotate keys, redeploy adapter

### Scenario E: RPC Node Outage

**Trigger**: Monitor reports RPC unreachable.

1. Switch to backup RPC:
   ```bash
   export STARKNET_RPC_URL="https://backup-rpc.example.com/rpc/v0_7"
   ```
2. Verify pool state is accessible from backup
3. Notify users if frontend is affected
4. Coordinate with RPC provider for resolution

### Scenario F: Proxy Upgrade Regression

**Trigger**: Contract behaves unexpectedly after a governance-approved proxy upgrade.

1. **Pause** all contracts immediately (Step 1)
2. Verify the deployed class hash matches the intended upgrade:
   ```bash
   starkli class-hash-at $POOL_ADDRESS --rpc $STARKNET_RPC_URL
   # Compare with expected class hash from the governance proposal
   ```
3. Check proxy governance roles are intact:
   ```bash
   starkli call $PROXY_ADDRESS get_governor --rpc $STARKNET_RPC_URL
   starkli call $PROXY_ADDRESS get_emergency_governor --rpc $STARKNET_RPC_URL
   ```
4. If class hash is wrong → unauthorized upgrade, treat as **P0 governance compromise**
5. If class hash is correct but behavior is wrong → rollback by upgrading to previous class hash through emergency governor
6. Run full invariant checks (`scripts/monitor.sh --once`) before unpausing

### Scenario G: Confirmed Fund Loss

**Trigger**: On-chain evidence shows value was extracted without a valid ZK proof, or pool balance is lower than expected.

1. **Pause** all contracts immediately — this is P0
2. **Preserve evidence** (Step 2) — do NOT interact with the exploit path
3. Capture the exploit transaction(s):
   ```bash
   starkli tx $EXPLOIT_TX_HASH --rpc $STARKNET_RPC_URL > exploit-tx.json
   ```
4. Compute expected pool balance from deposit/withdraw event history:
   ```bash
   # Sum all deposit events
   starkli events --from-block 0 --contract $POOL_ADDRESS \
     --keys 0x<DEPOSIT_EVENT_KEY> --rpc $STARKNET_RPC_URL > all-deposits.json
   # Sum all withdraw events
   starkli events --from-block 0 --contract $POOL_ADDRESS \
     --keys 0x<WITHDRAW_EVENT_KEY> --rpc $STARKNET_RPC_URL > all-withdrawals.json
   ```
5. Quantify the loss: `expected_balance - actual_balance = loss`
6. Engage external security firm for independent audit of the exploit
7. Communicate to users with full transparency (see Communication Templates)
8. Do NOT unpause until the root cause is patched and independently reviewed

---

## Key Rotation Procedures

### Scheduled Rotation (Non-Emergency)

Rotate keys on a regular cadence (recommended: quarterly) or whenever personnel changes occur.

#### 1. MultiSig Signer Rotation

The governance MultiSig controls owner-level operations (proof verifier upgrades, compliance oracle changes, proxy upgrades).

```bash
# Step 1: Current signers propose adding the new signer
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $EXISTING_SIGNER \
  --contract-address $MULTISIG_ADDRESS \
  --function propose \
  --calldata $MULTISIG_ADDRESS add_signer $NEW_SIGNER_ADDRESS

# Step 2: Collect M-of-N approvals from existing signers
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $SIGNER_2 \
  --contract-address $MULTISIG_ADDRESS \
  --function approve \
  --calldata $TX_ID

# Step 3: Forward the approved proposal to Timelock (or execute directly)
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $EXISTING_SIGNER \
  --contract-address $MULTISIG_ADDRESS \
  --function forward_to_timelock \
  --calldata $TX_ID

# Step 4: Remove the old signer via the same propose/approve/forward flow
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $EXISTING_SIGNER \
  --contract-address $MULTISIG_ADDRESS \
  --function propose \
  --calldata $MULTISIG_ADDRESS remove_signer $OLD_SIGNER_ADDRESS
```

**Verification**:

```bash
starkli call $MULTISIG_ADDRESS get_signers --rpc $STARKNET_RPC_URL
starkli call $MULTISIG_ADDRESS get_threshold --rpc $STARKNET_RPC_URL
```

#### 2. Operator Key Rotation

The operator can pause/unpause contracts and set fee recipients but cannot modify security-critical parameters.

```bash
# Owner or current operator sets the new operator
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $OWNER_ACCOUNT \
  --contract-address $POOL_ADDRESS \
  --function set_operator \
  --calldata $NEW_OPERATOR_ADDRESS
```

**Verification**:

```bash
starkli call $POOL_ADDRESS get_operator --rpc $STARKNET_RPC_URL
```

#### 3. Proof Verifier Rotation (Owner-Only via Timelock)

Replacing the proof verifier is a high-impact change — it must go through the Timelock.

```bash
# Step 1: Propose via Timelock
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $MULTISIG_ADDRESS \
  --contract-address $TIMELOCK_ADDRESS \
  --function propose \
  --calldata $POOL_ADDRESS set_proof_verifier $NEW_VERIFIER_ADDRESS

# Step 2: Wait for Timelock delay to elapse (check configured delay)
starkli call $TIMELOCK_ADDRESS get_delay --rpc $STARKNET_RPC_URL

# Step 3: Execute after delay
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $MULTISIG_ADDRESS \
  --contract-address $TIMELOCK_ADDRESS \
  --function execute \
  --calldata $QUEUED_TX_ID
```

**Verification**:

```bash
starkli call $POOL_ADDRESS get_proof_verifier --rpc $STARKNET_RPC_URL
```

#### 4. Compliance Oracle Rotation (Owner-Only via Timelock)

Same Timelock flow as the proof verifier:

```bash
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $MULTISIG_ADDRESS \
  --contract-address $TIMELOCK_ADDRESS \
  --function propose \
  --calldata $POOL_ADDRESS set_compliance_oracle $NEW_ORACLE_ADDRESS

# Wait for Timelock delay, then execute
```

#### 5. Epoch Manager Operator Rotation

```bash
sncast invoke \
  --url $STARKNET_RPC_URL \
  --account $OWNER_ACCOUNT \
  --contract-address $EPOCH_MANAGER_ADDRESS \
  --function set_operator \
  --calldata $NEW_EPOCH_OPERATOR
```

### Emergency Rotation

Use these procedures when a key is known or suspected compromised (P0/P1).

#### Compromised Operator Key

1. **Immediately** rotate via owner account (bypasses operator):
   ```bash
   sncast invoke \
     --url $STARKNET_RPC_URL \
     --account $OWNER_ACCOUNT \
     --contract-address $POOL_ADDRESS \
     --function set_operator \
     --calldata $EMERGENCY_OPERATOR_ADDRESS
   ```
2. Pause all contracts using the new operator
3. Investigate scope of compromise (check recent operator-level calls)
4. Assess whether any unauthorized pause/unpause or fee recipient changes occurred

#### Compromised MultiSig Signer

1. Remaining signers **immediately** propose and execute removal of compromised signer:
   ```bash
   sncast invoke \
     --url $STARKNET_RPC_URL \
     --account $SAFE_SIGNER \
     --contract-address $MULTISIG_ADDRESS \
     --function propose \
     --calldata $MULTISIG_ADDRESS remove_signer $COMPROMISED_SIGNER
   # Collect M-1 approvals and forward to timelock
   ```
2. If the compromised signer has pending proposals, cancel them before they reach Timelock execution
3. Add a replacement signer
4. Consider increasing the threshold (e.g., 2-of-3 → 3-of-4) if attack surface was wider than expected

#### Full Governance Compromise (Worst Case)

If the MultiSig itself or a majority of signers are compromised:

1. **Pause** all contracts using any available account with pause authority
2. Communicate publicly that governance is compromised — users should not interact with the protocol
3. Deploy new governance contracts (MultiSig + Timelock) with fresh signer set
4. Upgrade proxies to point to new governance (requires current proxy admin — if also compromised, this is unrecoverable on-chain)
5. Full post-mortem required

### Rotation Checklist

- [ ] New key generated on a hardware wallet / air-gapped device
- [ ] Old key revoked (removed from MultiSig / replaced as operator)
- [ ] Verified new key has correct permissions via read-only calls
- [ ] Team notified of rotation (internal comms)
- [ ] `scripts/monitor.sh` updated if address constants changed
- [ ] CI/CD secrets rotated if deployment keys changed
- [ ] Rotation logged in incident channel with UTC timestamp

---

## Communication Templates

### User-Facing (Status Page)

**Investigating**:

> We are investigating reports of [brief description]. The protocol is [operational/paused for safety]. No user funds are at risk. Updates will follow.

**Identified**:

> The issue has been identified as [root cause]. We are deploying a fix. The protocol is temporarily paused as a precaution.

**Resolved**:

> The incident has been resolved. [Brief description of fix]. All protocol functions have been restored. A full post-mortem will be published within 48 hours.

### Internal (Team Channel)

```
🚨 INCIDENT — [P0/P1/P2/P3]
Time: [UTC timestamp]
IC: [name]
Trigger: [alert name / user report]
Status: [INVESTIGATING / MITIGATING / RESOLVED]
Contracts paused: [yes/no — which ones]
Next action: [what's happening now]
```

---

## Post-Incident Checklist

- [ ] Timeline documented with UTC timestamps
- [ ] Root cause identified and documented
- [ ] All contracts unpaused and verified operational
- [ ] Test transaction confirmed end-to-end
- [ ] Monitoring thresholds adjusted if needed
- [ ] `docs/formal-invariants.md` updated if new invariant discovered
- [ ] `docs/security-checklist.md` updated with lessons learned
- [ ] Post-mortem written and shared (within 48 hours)
- [ ] User communication sent (status page updated)
- [ ] Issue filed for any follow-up code changes
- [ ] Runbook updated with new scenario if applicable
