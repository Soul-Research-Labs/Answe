#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# StarkPrivacy — Emergency pause / unpause contracts
# ──────────────────────────────────────────────────────────────
#
# Usage:
#   ./scripts/pause.sh [pause|unpause] [--network sepolia|mainnet]
#
# Required env vars:
#   STARKNET_RPC_URL, STARKNET_ACCOUNT, POOL_ADDRESS
#   Optionally: BRIDGE_ROUTER_ADDRESS, KAKAROT_ADAPTER_ADDRESS
#
set -euo pipefail

ACTION="${1:-pause}"
NETWORK="${2:-sepolia}"

RPC_URL="${STARKNET_RPC_URL:?Set STARKNET_RPC_URL}"
ACCOUNT="${STARKNET_ACCOUNT:?Set STARKNET_ACCOUNT}"
POOL="${POOL_ADDRESS:?Set POOL_ADDRESS}"

if [[ "$ACTION" != "pause" && "$ACTION" != "unpause" ]]; then
  echo "Usage: $0 [pause|unpause] [--network sepolia|mainnet]"
  exit 1
fi

echo "=== StarkPrivacy Emergency ${ACTION^} ==="
echo "Network : $NETWORK"
echo "Pool    : $POOL"
echo ""

# Pause/unpause the privacy pool
echo "[1/3] ${ACTION^} PrivacyPool..."
sncast --url "$RPC_URL" --account "$ACCOUNT" \
  invoke --contract-address "$POOL" \
  --function "$ACTION" \
  --calldata "" \
  --max-fee 0.01

# Pause/unpause bridge router (if configured)
if [[ -n "${BRIDGE_ROUTER_ADDRESS:-}" ]]; then
  echo "[2/3] ${ACTION^} BridgeRouter..."
  sncast --url "$RPC_URL" --account "$ACCOUNT" \
    invoke --contract-address "$BRIDGE_ROUTER_ADDRESS" \
    --function "$ACTION" \
    --calldata "" \
    --max-fee 0.01
else
  echo "[2/3] Skipping BridgeRouter (BRIDGE_ROUTER_ADDRESS not set)"
fi

# Pause/unpause Kakarot adapter (if configured)
if [[ -n "${KAKAROT_ADAPTER_ADDRESS:-}" ]]; then
  echo "[3/3] ${ACTION^} KakarotAdapter..."
  sncast --url "$RPC_URL" --account "$ACCOUNT" \
    invoke --contract-address "$KAKAROT_ADAPTER_ADDRESS" \
    --function "$ACTION" \
    --calldata "" \
    --max-fee 0.01
else
  echo "[3/3] Skipping KakarotAdapter (KAKAROT_ADAPTER_ADDRESS not set)"
fi

echo ""
echo "=== ${ACTION^} complete ==="
