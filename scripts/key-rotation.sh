#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# StarkPrivacy — Rotate operator / owner keys
# ──────────────────────────────────────────────────────────────
#
# Transfers ownership or operator role to a new account.
# This is critical for operational security — rotate keys regularly.
#
# Usage:
#   ./scripts/key-rotation.sh --role owner    --new-address 0x... --network sepolia
#   ./scripts/key-rotation.sh --role operator --new-address 0x... --network sepolia
#
# Required env vars:
#   STARKNET_RPC_URL, STARKNET_ACCOUNT, POOL_ADDRESS
#
set -euo pipefail

ROLE=""
NEW_ADDRESS=""
NETWORK="sepolia"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)        ROLE="$2";        shift 2 ;;
    --new-address) NEW_ADDRESS="$2"; shift 2 ;;
    --network)     NETWORK="$2";     shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$ROLE" || -z "$NEW_ADDRESS" ]]; then
  echo "Usage: $0 --role [owner|operator] --new-address 0x... [--network sepolia]"
  exit 1
fi

RPC_URL="${STARKNET_RPC_URL:?Set STARKNET_RPC_URL}"
ACCOUNT="${STARKNET_ACCOUNT:?Set STARKNET_ACCOUNT}"
POOL="${POOL_ADDRESS:?Set POOL_ADDRESS}"

echo "=== StarkPrivacy Key Rotation ==="
echo "Role       : $ROLE"
echo "New address: $NEW_ADDRESS"
echo "Pool       : $POOL"
echo "Network    : $NETWORK"
echo ""

case "$ROLE" in
  owner)
    echo "WARNING: Transferring ownership is irreversible."
    echo "The current owner account will lose all admin privileges."
    read -r -p "Type 'confirm' to proceed: " CONFIRMATION
    if [[ "$CONFIRMATION" != "confirm" ]]; then
      echo "Aborted."
      exit 1
    fi
    FUNCTION="transfer_ownership"
    ;;
  operator)
    FUNCTION="set_operator"
    ;;
  *)
    echo "Unknown role: $ROLE (expected: owner, operator)"
    exit 1
    ;;
esac

echo "Calling $FUNCTION($NEW_ADDRESS) on pool..."
sncast --url "$RPC_URL" --account "$ACCOUNT" \
  invoke --contract-address "$POOL" \
  --function "$FUNCTION" \
  --calldata "$NEW_ADDRESS" \
  --max-fee 0.01

echo ""
echo "=== Key rotation complete ==="
echo "New $ROLE: $NEW_ADDRESS"

if [[ "$ROLE" == "owner" ]]; then
  echo ""
  echo "IMPORTANT: Update STARKNET_ACCOUNT to the new owner's account for future admin operations."
fi
