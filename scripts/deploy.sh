#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# StarkPrivacy — Deploy all contracts to Starknet Sepolia
# ──────────────────────────────────────────────────────────────
#
# Prerequisites:
#   1. Install Starknet Foundry: https://foundry-rs.github.io/starknet-foundry/
#   2. Create an account:
#        sncast account create --url $RPC_URL --name deployer
#        sncast account deploy --url $RPC_URL --name deployer --max-fee 0.01
#   3. Export environment variables:
#        export STARKNET_RPC_URL="https://starknet-sepolia.public.blastapi.io/rpc/v0_7"
#        export STARKNET_ACCOUNT="deployer"
#        export STARKNET_KEYSTORE="~/.starknet_accounts/starknet_open_zeppelin_accounts.json"
#
# Usage:
#   ./scripts/deploy.sh [--network sepolia|mainnet]
#
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────

NETWORK="${1:---network}"
NETWORK_NAME="${2:-sepolia}"

if [[ "$NETWORK" == "--network" ]]; then
  NETWORK_NAME="${2:-sepolia}"
elif [[ "$NETWORK" == "sepolia" || "$NETWORK" == "mainnet" ]]; then
  NETWORK_NAME="$NETWORK"
fi

case "$NETWORK_NAME" in
  sepolia)
    RPC_URL="${STARKNET_RPC_URL:-https://starknet-sepolia.public.blastapi.io/rpc/v0_7}"
    ;;
  mainnet)
    RPC_URL="${STARKNET_RPC_URL:-https://starknet-mainnet.public.blastapi.io/rpc/v0_7}"
    ;;
  *)
    echo "Unknown network: $NETWORK_NAME (use sepolia or mainnet)"
    exit 1
    ;;
esac

ACCOUNT="${STARKNET_ACCOUNT:-deployer}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_FILE="$SCRIPT_DIR/deployments-${NETWORK_NAME}.json"

echo "═══════════════════════════════════════════════════════"
echo "  StarkPrivacy Deployment — $NETWORK_NAME"
echo "═══════════════════════════════════════════════════════"
echo "  RPC     : $RPC_URL"
echo "  Account : $ACCOUNT"
echo "  Output  : $OUTPUT_FILE"
echo ""

cd "$PROJECT_DIR"

# ─── Build ────────────────────────────────────────────────────

echo "▸ Building contracts..."
scarb build
echo "  ✓ Build complete"
echo ""

# ─── Helper: Declare + Deploy ─────────────────────────────────

declare_contract() {
  local contract_name="$1"
  echo "▸ Declaring $contract_name..."
  local result
  result=$(sncast --account "$ACCOUNT" --url "$RPC_URL" \
    declare \
    --contract-name "$contract_name" \
    2>&1) || true

  # Extract class hash from output
  local class_hash
  class_hash=$(echo "$result" | grep -oE "class_hash: 0x[0-9a-fA-F]+" | head -1 | awk '{print $2}')

  # If already declared, try to extract from the error
  if [[ -z "$class_hash" ]]; then
    class_hash=$(echo "$result" | grep -oE "0x[0-9a-fA-F]{60,}" | head -1)
  fi

  if [[ -z "$class_hash" ]]; then
    echo "  ✗ Failed to declare $contract_name"
    echo "  Output: $result"
    exit 1
  fi

  echo "  ✓ Class hash: $class_hash"
  echo "$class_hash"
}

deploy_contract() {
  local class_hash="$1"
  shift
  local constructor_args=("$@")

  local result
  result=$(sncast --account "$ACCOUNT" --url "$RPC_URL" \
    deploy \
    --class-hash "$class_hash" \
    --constructor-calldata "${constructor_args[@]}" \
    2>&1)

  local contract_address
  contract_address=$(echo "$result" | grep -oE "contract_address: 0x[0-9a-fA-F]+" | head -1 | awk '{print $2}')

  if [[ -z "$contract_address" ]]; then
    echo "  ✗ Deployment failed"
    echo "  Output: $result"
    exit 1
  fi

  echo "  ✓ Deployed at: $contract_address"
  echo "$contract_address"
}

# ─── Deploy Contracts ─────────────────────────────────────────

# We use a mock ERC-20 token address for testnet — replace for mainnet
# Override with NATIVE_TOKEN_ADDRESS env var for different networks
case "$NETWORK_NAME" in
  sepolia)
    # ETH on Sepolia
    NATIVE_TOKEN="${NATIVE_TOKEN_ADDRESS:-0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7}"
    ;;
  mainnet)
    # ETH on Mainnet
    NATIVE_TOKEN="${NATIVE_TOKEN_ADDRESS:-0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7}"
    ;;
esac
CHAIN_ID="${CHAIN_ID_OVERRIDE:-0x534e5f5345504f4c4941}"  # SN_SEPOLIA as felt (override for mainnet)
APP_ID="${APP_ID_OVERRIDE:-0x535441524b505249564143}"    # STARKPRIVAC as felt

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 1/11: Deploy NullifierRegistry"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
NULLIFIER_CLASS=$(declare_contract "NullifierRegistry")
echo "▸ Deploying NullifierRegistry..."
NULLIFIER_ADDR=$(deploy_contract "$NULLIFIER_CLASS")
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 2/11: Deploy SanctionsOracle (Compliance)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SANCTIONS_CLASS=$(declare_contract "SanctionsOracle")
echo "▸ Deploying SanctionsOracle..."
# Constructor: owner address (deployer)
DEPLOYER_ADDR=$(sncast --account "$ACCOUNT" --url "$RPC_URL" account address 2>&1 | grep -oE "0x[0-9a-fA-F]+" | head -1)
SANCTIONS_ADDR=$(deploy_contract "$SANCTIONS_CLASS" "$DEPLOYER_ADDR")
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3/11: Deploy PrivacyPool"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
POOL_CLASS=$(declare_contract "PrivacyPool")
echo "▸ Deploying PrivacyPool..."
# Constructor: native_token, compliance_oracle, chain_id, app_id, owner
POOL_ADDR=$(deploy_contract "$POOL_CLASS" \
  "$NATIVE_TOKEN" "$SANCTIONS_ADDR" "$CHAIN_ID" "$APP_ID" "$DEPLOYER_ADDR")
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 4/11: Deploy StealthRegistry + Factory"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
STEALTH_REG_CLASS=$(declare_contract "StealthRegistry")
echo "▸ Deploying StealthRegistry..."
STEALTH_REG_ADDR=$(deploy_contract "$STEALTH_REG_CLASS")
echo ""

STEALTH_FACTORY_CLASS=$(declare_contract "StealthAccountFactory")
echo "▸ Deploying StealthAccountFactory..."
STEALTH_FACTORY_ADDR=$(deploy_contract "$STEALTH_FACTORY_CLASS")
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 5/11: Deploy Bridge Contracts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
BRIDGE_CLASS=$(declare_contract "BridgeRouter")
echo "▸ Deploying BridgeRouter..."
# Constructor: pool, epoch_manager, owner
# We deploy EpochManager first
EPOCH_CLASS=$(declare_contract "EpochManager")
echo "▸ Deploying EpochManager..."
EPOCH_ADDR=$(deploy_contract "$EPOCH_CLASS" "$DEPLOYER_ADDR")
echo ""

BRIDGE_ADDR=$(deploy_contract "$BRIDGE_CLASS" \
  "$POOL_ADDR" "$EPOCH_ADDR" "$DEPLOYER_ADDR")
echo ""

L1_BRIDGE_CLASS=$(declare_contract "L1BridgeAdapter")
echo "▸ Deploying L1BridgeAdapter..."
L1_BRIDGE_ADDR=$(deploy_contract "$L1_BRIDGE_CLASS" "$DEPLOYER_ADDR")
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 6/11: Deploy MadaraAdapter"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
MADARA_CLASS=$(declare_contract "MadaraAdapter")
echo "▸ Deploying MadaraAdapter..."
# Constructor: owner, chain_id, pool, epoch_manager
MADARA_ADDR=$(deploy_contract "$MADARA_CLASS" \
  "$DEPLOYER_ADDR" "$CHAIN_ID" "$POOL_ADDR" "$EPOCH_ADDR")
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 7/11: Deploy Timelock"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TIMELOCK_CLASS=$(declare_contract "Timelock")
echo "▸ Deploying Timelock (min_delay=86400s / 24h)..."
# Constructor: proposer (deployer initially), min_delay (86400 = 24h)
TIMELOCK_ADDR=$(deploy_contract "$TIMELOCK_CLASS" "$DEPLOYER_ADDR" 86400)
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 8/11: Deploy MultiSig (2-of-3)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
MULTISIG_CLASS=$(declare_contract "MultiSig")
echo "▸ Deploying MultiSig..."
# Constructor: threshold=2, signer_count=3, signer_1, signer_2, signer_3
SIGNER_1="${MULTISIG_SIGNER_1:-$DEPLOYER_ADDR}"
SIGNER_2="${MULTISIG_SIGNER_2:-$DEPLOYER_ADDR}"
SIGNER_3="${MULTISIG_SIGNER_3:-$DEPLOYER_ADDR}"

# ─── Signer validation ───────────────────────────────────────
# All three signers must be distinct for meaningful M-of-N governance.
# On mainnet, we require explicit signer configuration (no deployer defaults).
if [[ "$SIGNER_1" == "$SIGNER_2" || "$SIGNER_1" == "$SIGNER_3" || "$SIGNER_2" == "$SIGNER_3" ]]; then
  if [[ "$NETWORK_NAME" == "mainnet" ]]; then
    echo "  ✗ ERROR: MultiSig signers must be distinct on mainnet."
    echo "    Set MULTISIG_SIGNER_1, MULTISIG_SIGNER_2, MULTISIG_SIGNER_3 to different addresses."
    exit 1
  else
    echo "  ⚠ WARNING: MultiSig signers are not unique — using deployer as all signers."
    echo "    This is acceptable for testnet only. Set MULTISIG_SIGNER_{1,2,3} for production."
  fi
fi

MULTISIG_ADDR=$(deploy_contract "$MULTISIG_CLASS" \
  2 3 "$SIGNER_1" "$SIGNER_2" "$SIGNER_3")
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 9/11: Deploy KakarotAdapter"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
KAKAROT_CLASS=$(declare_contract "KakarotAdapter")
echo "▸ Deploying KakarotAdapter..."
# Constructor: pool, owner, gas_price_factor (u256 = low,high)
# gas_price_factor = 10000 (1x multiplier)
KAKAROT_ADDR=$(deploy_contract "$KAKAROT_CLASS" \
  "$POOL_ADDR" "$DEPLOYER_ADDR" 10000 0)
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 10/11: Deploy UpgradeableProxy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PROXY_CLASS=$(declare_contract "UpgradeableProxy")
echo "▸ Deploying UpgradeableProxy..."
# Constructor: initial_class_hash (pool), governor (timelock), emergency_governor (deployer)
PROXY_ADDR=$(deploy_contract "$PROXY_CLASS" \
  "$POOL_CLASS" "$TIMELOCK_ADDR" "$DEPLOYER_ADDR")
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 11/11: Write deployment output"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cat > "$OUTPUT_FILE" << EOF
{
  "network": "$NETWORK_NAME",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contracts": {
    "NullifierRegistry": {
      "classHash": "$NULLIFIER_CLASS",
      "address": "$NULLIFIER_ADDR"
    },
    "SanctionsOracle": {
      "classHash": "$SANCTIONS_CLASS",
      "address": "$SANCTIONS_ADDR"
    },
    "PrivacyPool": {
      "classHash": "$POOL_CLASS",
      "address": "$POOL_ADDR"
    },
    "StealthRegistry": {
      "classHash": "$STEALTH_REG_CLASS",
      "address": "$STEALTH_REG_ADDR"
    },
    "StealthAccountFactory": {
      "classHash": "$STEALTH_FACTORY_CLASS",
      "address": "$STEALTH_FACTORY_ADDR"
    },
    "BridgeRouter": {
      "classHash": "$BRIDGE_CLASS",
      "address": "$BRIDGE_ADDR"
    },
    "EpochManager": {
      "classHash": "$EPOCH_CLASS",
      "address": "$EPOCH_ADDR"
    },
    "L1BridgeAdapter": {
      "classHash": "$L1_BRIDGE_CLASS",
      "address": "$L1_BRIDGE_ADDR"
    },
    "MadaraAdapter": {
      "classHash": "$MADARA_CLASS",
      "address": "$MADARA_ADDR"
    },
    "Timelock": {
      "classHash": "$TIMELOCK_CLASS",
      "address": "$TIMELOCK_ADDR"
    },
    "MultiSig": {
      "classHash": "$MULTISIG_CLASS",
      "address": "$MULTISIG_ADDR"
    },
    "KakarotAdapter": {
      "classHash": "$KAKAROT_CLASS",
      "address": "$KAKAROT_ADDR"
    },
    "UpgradeableProxy": {
      "classHash": "$PROXY_CLASS",
      "address": "$PROXY_ADDR"
    }
  },
  "config": {
    "nativeToken": "$NATIVE_TOKEN",
    "chainId": "$CHAIN_ID",
    "appId": "$APP_ID"
  }
}
EOF

echo ""
echo "✓ Deployment manifest written to: $OUTPUT_FILE"
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Deployment Complete!"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  PrivacyPool       : $POOL_ADDR"
echo "  NullifierRegistry : $NULLIFIER_ADDR"
echo "  SanctionsOracle   : $SANCTIONS_ADDR"
echo "  StealthRegistry   : $STEALTH_REG_ADDR"
echo "  StealthFactory    : $STEALTH_FACTORY_ADDR"
echo "  BridgeRouter      : $BRIDGE_ADDR"
echo "  EpochManager      : $EPOCH_ADDR"
echo "  L1BridgeAdapter   : $L1_BRIDGE_ADDR"
echo "  MadaraAdapter     : $MADARA_ADDR"
echo "  KakarotAdapter    : $KAKAROT_ADDR"
echo "  Timelock          : $TIMELOCK_ADDR"
echo "  MultiSig (2/3)    : $MULTISIG_ADDR"
echo "  UpgradeableProxy  : $PROXY_ADDR"
echo ""
echo "SDK quick-start:"
echo "  starkprivacy keygen"
echo "  starkprivacy deposit 1000 --pool $POOL_ADDR --rpc $RPC_URL"
echo ""

# ─── Post-deployment verification ──────────────────────────────

echo "▸ Verifying deployed contracts..."
verify_ok=true

for addr_label in "PrivacyPool:$POOL_ADDR" "EpochManager:$EPOCH_ADDR" "StealthRegistry:$STEALTH_REG_ADDR"; do
  label="${addr_label%%:*}"
  addr="${addr_label##*:}"
  result=$(sncast --account "$ACCOUNT" --url "$RPC_URL" \
    call --contract-address "$addr" --function "get_root" 2>&1) || true
  if echo "$result" | grep -qE "0x[0-9a-fA-F]+|felt"; then
    echo "  ✓ $label ($addr) — responding"
  else
    echo "  ⚠ $label ($addr) — could not verify (non-critical)"
    verify_ok=false
  fi
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ⚠️  POST-DEPLOYMENT CHECKLIST"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  1. Replace MultiSig signers with real governance addresses:"
echo "       MULTISIG_SIGNER_1=0x... MULTISIG_SIGNER_2=0x... MULTISIG_SIGNER_3=0x..."
echo "  2. Transfer pool ownership to Timelock → MultiSig chain"
echo "  3. Deploy StarkVerifier (not MockVerifier) for mainnet"
echo "  4. Verify all contract class hashes match compiled artifacts"
echo "  5. Fund the relayer account for gas"
echo ""
