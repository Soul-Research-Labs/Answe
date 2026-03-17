# Sepolia Deployment Runbook

## Pre-Flight Checklist

### Build Verification

- [ ] `scarb build` succeeds with zero warnings
- [ ] `snforge test` — all Cairo tests pass (currently 233)
- [ ] `npx tsc --noEmit` — SDK compiles cleanly
- [ ] `npx vitest run` — all SDK tests pass (currently 230)
- [ ] CI pipeline green on `main` branch

### Account Setup

- [ ] Deployer account created: `sncast account create --url $RPC_URL --name deployer`
- [ ] Deployer account deployed: `sncast account deploy --url $RPC_URL --name deployer --max-fee 0.01`
- [ ] Deployer account funded with ≥0.5 ETH on Sepolia
- [ ] Deployer address exported: `export STARKNET_ACCOUNT=deployer`

### MultiSig Signers

- [ ] Three distinct signer addresses generated (NEVER reuse deployer for all three in production)
- [ ] `MULTISIG_SIGNER_1` exported — Signer 1 address
- [ ] `MULTISIG_SIGNER_2` exported — Signer 2 address
- [ ] `MULTISIG_SIGNER_3` exported — Signer 3 address
- [ ] Each signer has a funded Starknet account (for governance transactions)

### Environment Variables

```bash
export STARKNET_RPC_URL="https://starknet-sepolia.public.blastapi.io/rpc/v0_7"
export STARKNET_ACCOUNT="deployer"
export MULTISIG_SIGNER_1="0x..."
export MULTISIG_SIGNER_2="0x..."
export MULTISIG_SIGNER_3="0x..."
```

---

## Deployment

### Step 1: Deploy All Contracts

```bash
./scripts/deploy.sh --network sepolia
```

**Expected output:**

- 11 contracts declared and deployed
- Deployment manifest written to `scripts/deployments-sepolia.json`
- Post-deployment verification shows all contracts responding

### Step 2: Verify Deployment Manifest

```bash
cat scripts/deployments-sepolia.json | python3 -m json.tool
```

Confirm all contract addresses are non-zero and class hashes are present.

### Step 3: Verify Contract Responses

```bash
# Check pool root
sncast --account deployer --url $STARKNET_RPC_URL \
  call --contract-address $(jq -r '.contracts.PrivacyPool.address' scripts/deployments-sepolia.json) \
  --function get_root

# Check stealth registry count
sncast --account deployer --url $STARKNET_RPC_URL \
  call --contract-address $(jq -r '.contracts.StealthRegistry.address' scripts/deployments-sepolia.json) \
  --function get_ephemeral_count
```

---

## Post-Deployment Governance Setup

### Step 4: Run Governance Setup Script

```bash
# If using separate signer accounts:
export MULTISIG_SIGNER_1_ACCOUNT="signer1"
export MULTISIG_SIGNER_2_ACCOUNT="signer2"

./scripts/setup-governance.sh --network sepolia
```

This script:

1. Sets the MultiSig timelock (requires 2-of-3 signer approval)
2. Transfers PrivacyPool ownership → Timelock
3. Transfers EpochManager ownership → Timelock
4. Transfers SanctionsOracle ownership → Timelock
5. Verifies all ownership transfers

### Step 5: Verify Governance Chain

```bash
POOL=$(jq -r '.contracts.PrivacyPool.address' scripts/deployments-sepolia.json)
TIMELOCK=$(jq -r '.contracts.Timelock.address' scripts/deployments-sepolia.json)
MULTISIG=$(jq -r '.contracts.MultiSig.address' scripts/deployments-sepolia.json)

# Verify pool owner is Timelock
sncast call --contract-address $POOL --function get_owner --url $STARKNET_RPC_URL

# Verify MultiSig timelock is set
sncast call --contract-address $MULTISIG --function get_timelock --url $STARKNET_RPC_URL
```

---

## SDK Configuration

### Step 6: Configure SDK for Sepolia

```typescript
import { StarkPrivacyClient, createProver } from "@starkprivacy/sdk";

const client = StarkPrivacyClient.fromSpendingKey(
  {
    rpcUrl: "https://starknet-sepolia.public.blastapi.io/rpc/v0_7",
    contracts: {
      pool: "POOL_ADDRESS_FROM_MANIFEST",
      stealthRegistry: "STEALTH_REG_ADDRESS",
      l1Bridge: "L1_BRIDGE_ADDRESS",
    },
    chainId: 0x534e5f5345504f4c4941n, // SN_SEPOLIA
    appId: 0x535441524b505249564143n,
    account: {
      address: "YOUR_ACCOUNT_ADDRESS",
      privateKey: "YOUR_PRIVATE_KEY",
    },
    // For testnet, LocalProver is sufficient
    prover: createProver("local"),
  },
  spendingKey,
);
```

### Step 7: Test E2E Flow

```bash
# Generate keys
npx starkprivacy keygen

# Deposit (requires funded account)
npx starkprivacy deposit 1000 \
  --pool POOL_ADDRESS \
  --rpc https://starknet-sepolia.public.blastapi.io/rpc/v0_7 \
  --key YOUR_SPENDING_KEY

# Check balance
npx starkprivacy balance \
  --pool POOL_ADDRESS \
  --rpc https://starknet-sepolia.public.blastapi.io/rpc/v0_7 \
  --key YOUR_SPENDING_KEY
```

---

## Relayer Setup

### Step 8: Fund Relayer Account

```bash
# Create relayer account
sncast account create --url $STARKNET_RPC_URL --name relayer
sncast account deploy --url $STARKNET_RPC_URL --name relayer --max-fee 0.01

# Fund with gas (send ETH from deployer or faucet)
```

### Step 9: Configure Relayer

```typescript
import { Relayer, SqliteJobStorage } from "@starkprivacy/sdk";

const relayer = new Relayer({
  rpcUrl: "https://starknet-sepolia.public.blastapi.io/rpc/v0_7",
  account: {
    address: "RELAYER_ADDRESS",
    privateKey: "RELAYER_PRIVATE_KEY",
  },
  contracts: { pool: "POOL_ADDRESS" },
  minFee: 100n,
  maxPending: 50,
  maxRetries: 3,
  storage: new SqliteJobStorage("./relayer-jobs.db"),
});
```

---

## Monitoring Setup

### Step 10: Start Monitor

```bash
export POOL_ADDRESS=$(jq -r '.contracts.PrivacyPool.address' scripts/deployments-sepolia.json)
export RPC_URL="https://starknet-sepolia.public.blastapi.io/rpc/v0_7"

./scripts/monitor.sh
```

---

## Post-Deployment Verification Checklist

- [ ] Deployment manifest exists with all 13 contracts
- [ ] All contracts respond to read calls
- [ ] MultiSig timelock is set to Timelock contract
- [ ] PrivacyPool owner = Timelock
- [ ] EpochManager owner = Timelock
- [ ] SanctionsOracle owner = Timelock
- [ ] Test deposit succeeds
- [ ] Test transfer succeeds
- [ ] Test withdrawal succeeds
- [ ] Relayer processes a job successfully
- [ ] Monitor script runs without errors
- [ ] Stealth address publish + scan works

## Rollback Procedure

If critical issues are found post-deployment:

1. **Pause the pool:** MultiSig → propose `pause()` on PrivacyPool → approve → forward
2. **Emergency pause:** If deployer still has emergency_governor role on Proxy, call `pause()` directly
3. **Do NOT upgrade** without thorough testing on a fresh devnet

## Known Limitations (Sepolia Testnet)

- MockVerifier is used (not StarkVerifier) — proofs are structurally validated but not cryptographically verified
- LocalProver backend — no real STARK proofs generated
- Default gas price factor on KakarotAdapter (10000) may need tuning
- Timelock delay set to 24h — may want shorter for testnet iteration

---

## Mainnet Promotion Checklist

Before deploying to mainnet, complete every item below on top of the Sepolia flow above.

### Verifier Swap

- [ ] Replace `MockVerifier` class hash with audited `StarkVerifier` class hash in deploy.sh or constructor calldata.
- [ ] Confirm prover backend is set to `stone` or `s-two` (never `local` on mainnet).
- [ ] Run one full deposit → transfer → withdraw cycle on Sepolia using non-mock verifier before mainnet deploy.

### Contract Class-Hash Validation

After deployment, verify every on-chain class hash matches the locally compiled artifact:

```bash
MANIFEST="scripts/deployments-mainnet.json"
for name in PrivacyPool NullifierRegistry SanctionsOracle StealthRegistry \
            BridgeRouter EpochManager Timelock MultiSig KakarotAdapter UpgradeableProxy; do
  expected=$(jq -r ".contracts.$name.classHash" "$MANIFEST")
  onchain=$(starkli class-hash-at \
    "$(jq -r ".contracts.$name.address" "$MANIFEST")" \
    --rpc "$STARKNET_RPC_URL")
  if [[ "$expected" == "$onchain" ]]; then
    echo "✓ $name class hash matches"
  else
    echo "✗ $name MISMATCH — expected $expected, got $onchain"
  fi
done
```

### Signer Hygiene

- [ ] All three MultiSig signers are independent hardware wallets or institutional custodians.
- [ ] No signer private key is stored in plaintext or environment variables on any server.
- [ ] Emergency governor key is held in a break-glass procedure (see `docs/incident-response.md`).

### Timelock Tuning

- [ ] Set `min_delay` to at least 48 h for mainnet (constructor arg in `deploy.sh`).
- [ ] Confirm Timelock delay change itself goes through the governance pipeline.

### Relayer Hardening

- [ ] Relayer account private key managed via KMS or encrypted keystore — never `.env` file on mainnet.
- [ ] `maxPending` and `minFee` tuned to expected mainnet throughput.
- [ ] SQLite database file resides on persistent, backed-up storage (not `/tmp`).

### Monitoring

- [ ] `ALERT_WEBHOOK_URL` points to an actively monitored channel.
- [ ] `MONITOR_INTERVAL` set to ≤30 s for mainnet.
- [ ] L1 bridge adapter pause state is included in health checks (already in monitor.sh).
- [ ] Log rotation configured (see monitor.sh `--rotate` support or external logrotate).

### Disaster Recovery

| Scenario                   | Action                                                                                                    |
| -------------------------- | --------------------------------------------------------------------------------------------------------- |
| Exploitable bug found      | Emergency governor calls `pause()` on UpgradeableProxy immediately.                                       |
| Governance key compromised | Rotate emergency governor via proxy; revoke compromised signer in MultiSig.                               |
| RPC provider outage        | Fail over to backup RPC (`STARKNET_RPC_URL` swap). Monitor and relayer pick up from last persisted state. |
| Relayer DB corruption      | Restore from last WAL checkpoint backup; relayer resumes from persisted job counter.                      |
| Merkle tree corruption     | Pause pool, snapshot state via indexer, investigate root cause before any upgrade.                        |
