#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# StarkPrivacy — Rollback to previous contract class
# ──────────────────────────────────────────────────────────────
#
# Reverts a contract to a previous class hash. Use this if an upgrade
# introduced a bug. Requires the contract to implement upgrade().
#
# Usage:
#   ./scripts/rollback.sh --contract pool --class-hash 0x... --network sepolia
#
# Required env vars:
#   STARKNET_RPC_URL, STARKNET_ACCOUNT
#   POOL_ADDRESS or BRIDGE_ROUTER_ADDRESS (depending on --contract)
#
set -euo pipefail

CONTRACT=""
CLASS_HASH=""
NETWORK="sepolia"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract)   CONTRACT="$2";   shift 2 ;;
    --class-hash) CLASS_HASH="$2"; shift 2 ;;
    --network)    NETWORK="$2";    shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$CONTRACT" || -z "$CLASS_HASH" ]]; then
  echo "Usage: $0 --contract [pool|bridge|kakarot] --class-hash 0x... [--network sepolia]"
  exit 1
fi

RPC_URL="${STARKNET_RPC_URL:?Set STARKNET_RPC_URL}"
ACCOUNT="${STARKNET_ACCOUNT:?Set STARKNET_ACCOUNT}"

case "$CONTRACT" in
  pool)    TARGET="${POOL_ADDRESS:?Set POOL_ADDRESS}" ;;
  bridge)  TARGET="${BRIDGE_ROUTER_ADDRESS:?Set BRIDGE_ROUTER_ADDRESS}" ;;
  kakarot) TARGET="${KAKAROT_ADAPTER_ADDRESS:?Set KAKAROT_ADAPTER_ADDRESS}" ;;
  *)       echo "Unknown contract: $CONTRACT"; exit 1 ;;
esac

echo "=== StarkPrivacy Rollback ==="
echo "Contract  : $CONTRACT ($TARGET)"
echo "Class hash: $CLASS_HASH"
echo "Network   : $NETWORK"
echo ""

# Safety: pause the contract first
echo "[1/2] Pausing $CONTRACT before rollback..."
sncast --url "$RPC_URL" --account "$ACCOUNT" \
  invoke --contract-address "$TARGET" \
  --function "pause" \
  --calldata "" \
  --max-fee 0.01 2>/dev/null || echo "  (already paused or no pause function)"

echo "[2/2] Rolling back to class hash $CLASS_HASH..."
sncast --url "$RPC_URL" --account "$ACCOUNT" \
  invoke --contract-address "$TARGET" \
  --function "upgrade" \
  --calldata "$CLASS_HASH" \
  --max-fee 0.05

echo ""
echo "=== Rollback complete ==="
echo "IMPORTANT: Contract is still PAUSED. Run ./scripts/pause.sh unpause to resume."
