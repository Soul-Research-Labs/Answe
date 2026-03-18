#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# StarkPrivacy — Upgrade contract (replace class hash)
# ──────────────────────────────────────────────────────────────
#
# Deploys a new class and calls `upgrade(new_class_hash)` on the target
# proxy contract. Requires the contract to implement the upgrade interface.
#
# Usage:
#   ./scripts/upgrade.sh --contract pool --network sepolia
#   ./scripts/upgrade.sh --contract bridge --network sepolia
#
# Required env vars:
#   STARKNET_RPC_URL, STARKNET_ACCOUNT
#   POOL_ADDRESS or BRIDGE_ROUTER_ADDRESS (depending on --contract)
#
set -euo pipefail

CONTRACT=""
NETWORK="sepolia"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) CONTRACT="$2"; shift 2 ;;
    --network)  NETWORK="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$CONTRACT" ]]; then
  echo "Usage: $0 --contract [pool|bridge|kakarot] --network [sepolia|mainnet]"
  exit 1
fi

RPC_URL="${STARKNET_RPC_URL:?Set STARKNET_RPC_URL}"
ACCOUNT="${STARKNET_ACCOUNT:?Set STARKNET_ACCOUNT}"

echo "=== StarkPrivacy Contract Upgrade ==="
echo "Contract: $CONTRACT"
echo "Network : $NETWORK"
echo ""

# Build contracts first
echo "[1/3] Building contracts..."
scarb build

# Determine which contract to upgrade
case "$CONTRACT" in
  pool)
    TARGET="${POOL_ADDRESS:?Set POOL_ADDRESS}"
    CLASS_NAME="PrivacyPool"
    ;;
  bridge)
    TARGET="${BRIDGE_ROUTER_ADDRESS:?Set BRIDGE_ROUTER_ADDRESS}"
    CLASS_NAME="BridgeRouter"
    ;;
  kakarot)
    TARGET="${KAKAROT_ADAPTER_ADDRESS:?Set KAKAROT_ADAPTER_ADDRESS}"
    CLASS_NAME="KakarotAdapter"
    ;;
  *)
    echo "Unknown contract: $CONTRACT (expected: pool, bridge, kakarot)"
    exit 1
    ;;
esac

echo "[2/3] Declaring new class for $CLASS_NAME..."
DECLARE_OUTPUT=$(sncast --url "$RPC_URL" --account "$ACCOUNT" \
  declare --contract-name "$CLASS_NAME" \
  --max-fee 0.05 2>&1)

NEW_CLASS_HASH=$(echo "$DECLARE_OUTPUT" | grep "class_hash:" | awk '{print $2}')

if [[ -z "$NEW_CLASS_HASH" ]]; then
  echo "ERROR: Failed to extract class_hash from declare output:"
  echo "$DECLARE_OUTPUT"
  exit 1
fi

echo "  New class hash: $NEW_CLASS_HASH"

echo "[3/3] Upgrading $CONTRACT at $TARGET..."
sncast --url "$RPC_URL" --account "$ACCOUNT" \
  invoke --contract-address "$TARGET" \
  --function "upgrade" \
  --calldata "$NEW_CLASS_HASH" \
  --max-fee 0.05

echo ""
echo "=== Upgrade complete ==="
echo "Contract : $TARGET"
echo "New class: $NEW_CLASS_HASH"
