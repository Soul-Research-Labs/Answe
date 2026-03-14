#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# StarkPrivacy — Run starknet-devnet-rs and deploy contracts
# ──────────────────────────────────────────────────────────────
#
# Prerequisites:
#   cargo install starknet-devnet
#   OR:  docker pull shardlabs/starknet-devnet-rs
#
# Usage:
#   ./scripts/devnet.sh          # Start devnet + deploy
#   ./scripts/devnet.sh --stop   # Stop running devnet
#
set -euo pipefail

DEVNET_PORT="${DEVNET_PORT:-5050}"
DEVNET_URL="http://127.0.0.1:${DEVNET_PORT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PID_FILE="$SCRIPT_DIR/.devnet.pid"

stop_devnet() {
  if [[ -f "$PID_FILE" ]]; then
    local pid_data
    pid_data=$(cat "$PID_FILE")
    if [[ "$pid_data" == docker:* ]]; then
      local container_id="${pid_data#docker:}"
      echo "▸ Stopping devnet (Docker container $container_id)..."
      docker stop "$container_id" 2>/dev/null || docker stop starkprivacy-devnet 2>/dev/null
      rm -f "$PID_FILE"
      echo "  ✓ Devnet stopped"
    elif kill -0 "$pid_data" 2>/dev/null; then
      echo "▸ Stopping devnet (PID $pid_data)..."
      kill "$pid_data"
      rm -f "$PID_FILE"
      echo "  ✓ Devnet stopped"
    else
      rm -f "$PID_FILE"
      echo "  Devnet not running"
    fi
  else
    echo "  No PID file found — devnet not managed by this script"
  fi
}

if [[ "${1:-}" == "--stop" ]]; then
  stop_devnet
  exit 0
fi

echo "═══════════════════════════════════════════════════════"
echo "  StarkPrivacy — Local Devnet Setup"
echo "═══════════════════════════════════════════════════════"
echo ""

# Check if devnet is already running
if curl -s "$DEVNET_URL/is_alive" > /dev/null 2>&1; then
  echo "  ✓ Devnet already running at $DEVNET_URL"
else
  echo "▸ Starting starknet-devnet-rs on port $DEVNET_PORT..."

  if command -v starknet-devnet &> /dev/null; then
    starknet-devnet \
      --port "$DEVNET_PORT" \
      --seed 42 \
      --gas-price 1 \
      --accounts 3 \
      --initial-balance 1000000000000000000000 \
      &
    echo $! > "$PID_FILE"
  elif command -v docker &> /dev/null; then
    CONTAINER_ID=$(docker run -d --rm \
      -p "${DEVNET_PORT}:5050" \
      --name starkprivacy-devnet \
      shardlabs/starknet-devnet-rs:latest \
      --seed 42 \
      --gas-price 1 \
      --accounts 3 \
      --initial-balance 1000000000000000000000)
    echo "docker:${CONTAINER_ID}" > "$PID_FILE"
  else
    echo "  ✗ Neither 'starknet-devnet' nor 'docker' found."
    echo "    Install: cargo install starknet-devnet"
    echo "    Or:      docker pull shardlabs/starknet-devnet-rs"
    exit 1
  fi

  # Wait for devnet to be ready
  echo "  Waiting for devnet..."
  for i in $(seq 1 30); do
    if curl -s "$DEVNET_URL/is_alive" > /dev/null 2>&1; then
      echo "  ✓ Devnet ready at $DEVNET_URL"
      break
    fi
    sleep 1
    if [[ $i -eq 30 ]]; then
      echo "  ✗ Devnet failed to start within 30s"
      exit 1
    fi
  done
fi

echo ""

# Fetch predeployed accounts
echo "▸ Fetching predeployed accounts..."
ACCOUNTS=$(curl -s "$DEVNET_URL/predeployed_accounts")
DEPLOYER_ADDR=$(echo "$ACCOUNTS" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['address'])" 2>/dev/null || echo "")
DEPLOYER_KEY=$(echo "$ACCOUNTS" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['private_key'])" 2>/dev/null || echo "")

if [[ -z "$DEPLOYER_ADDR" ]]; then
  echo "  ✗ Could not fetch predeployed accounts"
  echo "  Try: curl $DEVNET_URL/predeployed_accounts"
  exit 1
fi

echo "  ✓ Deployer: $DEPLOYER_ADDR"
echo ""

# Write devnet config for SDK tests
cat > "$SCRIPT_DIR/devnet-config.json" << EOF
{
  "rpcUrl": "$DEVNET_URL/rpc",
  "accounts": $(echo "$ACCOUNTS" | python3 -c "
import sys, json
accts = json.load(sys.stdin)
out = []
for a in accts[:3]:
    out.append({'address': a['address'], 'privateKey': a['private_key']})
print(json.dumps(out, indent=2))
" 2>/dev/null || echo "[]"),
  "nativeToken": "0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7"
}
EOF

echo "  ✓ Devnet config written to: $SCRIPT_DIR/devnet-config.json"
echo ""
echo "  To deploy contracts:"
echo "    export STARKNET_RPC_URL=$DEVNET_URL/rpc"
echo "    export STARKNET_ACCOUNT=deployer"
echo "    ./scripts/deploy.sh --network sepolia"
echo ""
echo "  To stop devnet:"
echo "    ./scripts/devnet.sh --stop"
echo ""
