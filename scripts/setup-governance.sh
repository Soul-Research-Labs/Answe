#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# StarkPrivacy — Post-deployment governance setup
# ──────────────────────────────────────────────────────────────
#
# Automates the post-deployment checklist:
#   1. Set MultiSig timelock to the deployed Timelock contract
#   2. Transfer PrivacyPool ownership from deployer to Timelock
#   3. Transfer EpochManager ownership from deployer to Timelock
#   4. Transfer SanctionsOracle ownership from deployer to Timelock
#   5. Verify all ownership transfers
#
# Prerequisites:
#   - Contracts must be deployed (run deploy.sh first)
#   - Deployment manifest must exist (deployments-{network}.json)
#   - MultiSig signers must have access to sign transactions
#
# Usage:
#   ./scripts/setup-governance.sh [--network sepolia|mainnet]
#
# Environment:
#   STARKNET_RPC_URL   — Starknet RPC endpoint (overrides default)
#   STARKNET_ACCOUNT   — Starknet account name (default: deployer)
#   MULTISIG_SIGNER_1_ACCOUNT — Account name of signer 1
#   MULTISIG_SIGNER_2_ACCOUNT — Account name of signer 2
#
set -euo pipefail

# ─── Parse network ────────────────────────────────────────────

NETWORK_NAME="${1:-sepolia}"
if [[ "$NETWORK_NAME" == "--network" ]]; then
  NETWORK_NAME="${2:-sepolia}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/deployments-${NETWORK_NAME}.json"

if [[ ! -f "$MANIFEST" ]]; then
  echo "✗ Deployment manifest not found: $MANIFEST"
  echo "  Run deploy.sh first."
  exit 1
fi

case "$NETWORK_NAME" in
  sepolia)
    RPC_URL="${STARKNET_RPC_URL:-https://starknet-sepolia.public.blastapi.io/rpc/v0_7}"
    ;;
  mainnet)
    RPC_URL="${STARKNET_RPC_URL:-https://starknet-mainnet.public.blastapi.io/rpc/v0_7}"
    ;;
  *)
    echo "Unknown network: $NETWORK_NAME"
    exit 1
    ;;
esac

# ─── Read deployment addresses ────────────────────────────────

read_address() {
  local contract_name="$1"
  python3 -c "
import json,sys
with open('$MANIFEST') as f:
    d = json.load(f)
print(d['contracts']['$contract_name']['address'])
"
}

POOL_ADDR=$(read_address "PrivacyPool")
TIMELOCK_ADDR=$(read_address "Timelock")
MULTISIG_ADDR=$(read_address "MultiSig")
EPOCH_ADDR=$(read_address "EpochManager")
SANCTIONS_ADDR=$(read_address "SanctionsOracle")

echo "═══════════════════════════════════════════════════════"
echo "  StarkPrivacy Governance Setup — $NETWORK_NAME"
echo "═══════════════════════════════════════════════════════"
echo ""

# ─── Mainnet safety gate ──────────────────────────────────────

if [[ "$NETWORK_NAME" == "mainnet" ]]; then
  echo "  ⚠ MAINNET governance setup — ownership transfers are irreversible."
  echo ""
  if [[ "${MAINNET_CONFIRM:-}" == "yes" ]]; then
    echo "  MAINNET_CONFIRM=yes detected — proceeding."
  elif [[ -t 0 ]]; then
    read -rp "  Type 'CONFIRM GOVERNANCE' to continue: " confirm
    if [[ "$confirm" != "CONFIRM GOVERNANCE" ]]; then
      echo "  Aborted."
      exit 1
    fi
  else
    echo "  ✗ Non-interactive mode requires MAINNET_CONFIRM=yes"
    exit 1
  fi
  echo ""
fi

echo "  Pool          : $POOL_ADDR"
echo "  Timelock      : $TIMELOCK_ADDR"
echo "  MultiSig      : $MULTISIG_ADDR"
echo "  EpochManager  : $EPOCH_ADDR"
echo "  SanctionsOracle: $SANCTIONS_ADDR"
echo ""

# ─── Account config ───────────────────────────────────────────

DEPLOYER_ACCOUNT="${STARKNET_ACCOUNT:-deployer}"
SIGNER_1_ACCOUNT="${MULTISIG_SIGNER_1_ACCOUNT:-$DEPLOYER_ACCOUNT}"
SIGNER_2_ACCOUNT="${MULTISIG_SIGNER_2_ACCOUNT:-$DEPLOYER_ACCOUNT}"

invoke_contract() {
  local account="$1"
  local contract="$2"
  local function="$3"
  shift 3
  local args=("$@")

  echo "  → $function($contract)"
  sncast --account "$account" --url "$RPC_URL" \
    invoke \
    --contract-address "$contract" \
    --function "$function" \
    --calldata "${args[@]}" \
    2>&1
}

call_contract() {
  local contract="$1"
  local function="$2"
  shift 2
  local args=("$@")

  sncast --account "$DEPLOYER_ACCOUNT" --url "$RPC_URL" \
    call \
    --contract-address "$contract" \
    --function "$function" \
    --calldata "${args[@]}" \
    2>&1
}

# ─── Step 1: Set MultiSig timelock (requires threshold approvals) ─

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 1/4: Set MultiSig Timelock"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Two signers must call set_timelock with the same address."
echo ""

echo "  ▸ Signer 1 calling set_timelock..."
invoke_contract "$SIGNER_1_ACCOUNT" "$MULTISIG_ADDR" "set_timelock" "$TIMELOCK_ADDR"
echo ""

echo "  ▸ Signer 2 calling set_timelock..."
invoke_contract "$SIGNER_2_ACCOUNT" "$MULTISIG_ADDR" "set_timelock" "$TIMELOCK_ADDR"
echo ""

# Verify
echo "  ▸ Verifying timelock is set..."
RESULT=$(call_contract "$MULTISIG_ADDR" "get_timelock")
if echo "$RESULT" | grep -qi "$TIMELOCK_ADDR"; then
  echo "  ✓ Timelock set to $TIMELOCK_ADDR"
else
  echo "  ⚠ Could not verify timelock (non-critical — check manually)"
  echo "  Result: $RESULT"
fi
echo ""

# ─── Step 2: Transfer PrivacyPool ownership to Timelock ───────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 2/4: Transfer PrivacyPool ownership → Timelock"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
invoke_contract "$DEPLOYER_ACCOUNT" "$POOL_ADDR" "transfer_ownership" "$TIMELOCK_ADDR"
echo ""

# ─── Step 3: Transfer EpochManager ownership to Timelock ──────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3/4: Transfer EpochManager ownership → Timelock"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
invoke_contract "$DEPLOYER_ACCOUNT" "$EPOCH_ADDR" "transfer_ownership" "$TIMELOCK_ADDR"
echo ""

# ─── Step 4: Transfer SanctionsOracle ownership to Timelock ───

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 4/4: Transfer SanctionsOracle ownership → Timelock"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
invoke_contract "$DEPLOYER_ACCOUNT" "$SANCTIONS_ADDR" "transfer_ownership" "$TIMELOCK_ADDR"
echo ""

# ─── Verify ───────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════"
echo "  Verification"
echo "═══════════════════════════════════════════════════════"
echo ""

verify_owner() {
  local name="$1"
  local addr="$2"
  local expected="$3"

  RESULT=$(call_contract "$addr" "get_owner" 2>&1) || true
  if echo "$RESULT" | grep -qi "$expected"; then
    echo "  ✓ $name owner = Timelock"
  else
    echo "  ⚠ $name owner check — verify manually"
    echo "    Result: $RESULT"
  fi
}

verify_owner "PrivacyPool" "$POOL_ADDR" "$TIMELOCK_ADDR"
verify_owner "EpochManager" "$EPOCH_ADDR" "$TIMELOCK_ADDR"
verify_owner "SanctionsOracle" "$SANCTIONS_ADDR" "$TIMELOCK_ADDR"
echo ""

echo "═══════════════════════════════════════════════════════"
echo "  Governance Setup Complete!"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  Governance chain: MultiSig (2/3) → Timelock (24h) → Contracts"
echo ""
echo "  To propose a governance action:"
echo "    1. Signer calls MultiSig.propose(target, selector, calldata_hash)"
echo "    2. Second signer calls MultiSig.approve(proposal_id)"
echo "    3. Any signer calls MultiSig.forward_to_timelock(proposal_id)"
echo "    4. After 24h delay, execute on Timelock"
echo ""
