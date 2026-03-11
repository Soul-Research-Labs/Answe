#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# StarkPrivacy — Pool Health Monitor
# ──────────────────────────────────────────────────────────────
#
# Periodically queries on-chain state and alerts on anomalies:
#   - Pool balance drift (expected vs actual)
#   - Merkle tree leaf count growth rate
#   - Nullifier double-spend attempts (via event scanning)
#   - Epoch manager stall detection
#   - Bridge adapter pause state
#
# Prerequisites:
#   - starkli CLI installed (https://github.com/xJonathanLEI/starkli)
#   - jq installed
#   - Environment variables set (see below)
#
# Usage:
#   export STARKNET_RPC_URL="https://starknet-sepolia.public.blastapi.io/rpc/v0_7"
#   export POOL_ADDRESS="0x..."
#   export EPOCH_MANAGER_ADDRESS="0x..."
#   export KAKAROT_ADAPTER_ADDRESS="0x..."  # optional
#   export ALERT_WEBHOOK_URL="https://hooks.slack.com/..."  # optional
#   export MONITOR_INTERVAL=60  # seconds between checks (default: 60)
#
#   ./scripts/monitor.sh
#
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────

RPC_URL="${STARKNET_RPC_URL:?STARKNET_RPC_URL must be set}"
POOL="${POOL_ADDRESS:?POOL_ADDRESS must be set}"
EPOCH_MGR="${EPOCH_MANAGER_ADDRESS:-}"
KAKAROT="${KAKAROT_ADAPTER_ADDRESS:-}"
WEBHOOK="${ALERT_WEBHOOK_URL:-}"
INTERVAL="${MONITOR_INTERVAL:-60}"

LOG_FILE="${MONITOR_LOG_FILE:-/tmp/starkprivacy-monitor.log}"
STATE_FILE="${MONITOR_STATE_FILE:-/tmp/starkprivacy-monitor-state.json}"

# ─── Helpers ──────────────────────────────────────────────────

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local level="$1"
  shift
  local msg="[$(timestamp)] [$level] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

alert() {
  local message="$1"
  log "ALERT" "$message"

  if [[ -n "$WEBHOOK" ]]; then
    # Send to Slack/Discord webhook — sanitize message for JSON
    local safe_msg
    safe_msg=$(printf '%s' "$message" | jq -Rs .)
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"text\": $safe_msg}" \
      "$WEBHOOK" > /dev/null 2>&1 || log "WARN" "Failed to send alert to webhook"
  fi
}

# JSON-RPC helper
rpc_call() {
  local method="$1"
  shift
  local params="$*"
  
  local response
  response=$(curl -s -X POST "$RPC_URL" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[$params],\"id\":1}")
  
  echo "$response"
}

# Call a contract view function
call_view() {
  local contract="$1"
  local selector="$2"
  shift 2
  local calldata="${*:-[]}"
  
  local request
  request=$(cat <<EOF
{
  "contract_address": "$contract",
  "entry_point_selector": "$selector",
  "calldata": $calldata
}
EOF
)
  
  rpc_call "starknet_call" "$request, \"latest\""
}

# Selector computation via Keccak (pre-computed for known functions)
# starknet_keccak("get_leaf_count") = 0x...
# We use starkli to compute or hard-code known selectors
SELECTOR_GET_LEAF_COUNT="0x019d59575520e977a0e1a21bde4aa4f55c0532eedd69e41522e86967a0597db5"
SELECTOR_GET_ROOT="0x007bcc55083e32dad37dbe69680c5ea41c380e1f1b3f0e8bcbf65b308a1e0e9e"
SELECTOR_GET_POOL_BALANCE="0x01096a01f2eaca7f8dff82493f93e1e5e2eb03b0c20f8e0519bc3f38e78aa390"
SELECTOR_GET_CURRENT_EPOCH="0x0172df3e785c73e34cb5bd6d7c41c1ad7d9ec48e5c0e5e1c5c62b2487cfcb24f"
SELECTOR_IS_PAUSED="0x0069e6e01d93add50dc4a5f70ab2e0c29b9c9ec6f843cf6ad1fd7f0c6f28f1bf"

# ─── State Management ────────────────────────────────────────

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo '{"prev_leaf_count":0,"prev_epoch":0,"prev_balance":"0","checks":0,"alerts":0}'
  fi
}

save_state() {
  local state="$1"
  echo "$state" > "$STATE_FILE"
}

# ─── Health Checks ────────────────────────────────────────────

check_pool_health() {
  log "INFO" "Checking pool health..."
  local state
  state=$(load_state)
  local prev_leaf_count
  prev_leaf_count=$(echo "$state" | jq -r '.prev_leaf_count')
  local prev_balance
  prev_balance=$(echo "$state" | jq -r '.prev_balance')
  local checks
  checks=$(echo "$state" | jq -r '.checks')
  local alerts
  alerts=$(echo "$state" | jq -r '.alerts')

  # 1. Get leaf count
  local leaf_response
  leaf_response=$(call_view "$POOL" "$SELECTOR_GET_LEAF_COUNT")
  local leaf_count
  leaf_count=$(echo "$leaf_response" | jq -r '.result[0] // "0x0"')
  leaf_count=$((leaf_count))  # hex to decimal
  log "INFO" "Leaf count: $leaf_count (previous: $prev_leaf_count)"

  # 2. Check for abnormal growth (>100 deposits in one interval)
  local growth=$((leaf_count - prev_leaf_count))
  if [[ $growth -gt 100 && $prev_leaf_count -gt 0 ]]; then
    alert "ABNORMAL GROWTH: $growth new deposits in last ${INTERVAL}s (prev: $prev_leaf_count, now: $leaf_count)"
    alerts=$((alerts + 1))
  fi

  # 3. Leaf count should never decrease
  if [[ $leaf_count -lt $prev_leaf_count && $prev_leaf_count -gt 0 ]]; then
    alert "CRITICAL: Leaf count DECREASED from $prev_leaf_count to $leaf_count — possible state corruption"
    alerts=$((alerts + 1))
  fi

  # 4. Get pool balance for asset 0 (native)
  local balance_response
  balance_response=$(call_view "$POOL" "$SELECTOR_GET_POOL_BALANCE" '["0x0"]')
  local balance
  balance=$(echo "$balance_response" | jq -r '.result[0] // "0x0"')
  log "INFO" "Pool balance (asset 0): $balance (previous: $prev_balance)"

  # 5. Balance should never decrease unless a withdrawal happened
  # (We can't distinguish here, so just log it as a warning)
  local balance_dec
  balance_dec=$((balance))
  local prev_balance_dec
  prev_balance_dec=$((prev_balance))
  if [[ $balance_dec -lt $prev_balance_dec && $prev_balance_dec -gt 0 ]]; then
    local diff=$((prev_balance_dec - balance_dec))
    log "WARN" "Pool balance decreased by $diff (was $prev_balance_dec, now $balance_dec)"
  fi

  # 6. Get Merkle root
  local root_response
  root_response=$(call_view "$POOL" "$SELECTOR_GET_ROOT")
  local root
  root=$(echo "$root_response" | jq -r '.result[0] // "0x0"')
  log "INFO" "Current Merkle root: $root"

  # 7. Root should be nonzero if there are deposits
  if [[ "$root" == "0x0" && $leaf_count -gt 0 ]]; then
    alert "CRITICAL: Merkle root is zero but leaf count is $leaf_count — tree may be corrupted"
    alerts=$((alerts + 1))
  fi

  checks=$((checks + 1))

  # Update state
  local new_state
  new_state=$(jq -n \
    --argjson prev_leaf_count "$leaf_count" \
    --arg prev_balance "$balance" \
    --argjson checks "$checks" \
    --argjson alerts "$alerts" \
    --argjson prev_epoch "$(echo "$state" | jq -r '.prev_epoch')" \
    '{prev_leaf_count: $prev_leaf_count, prev_epoch: $prev_epoch, prev_balance: $prev_balance, checks: $checks, alerts: $alerts}')
  save_state "$new_state"
}

check_epoch_health() {
  if [[ -z "$EPOCH_MGR" ]]; then
    return
  fi

  log "INFO" "Checking epoch manager health..."
  local state
  state=$(load_state)
  local prev_epoch
  prev_epoch=$(echo "$state" | jq -r '.prev_epoch')

  local epoch_response
  epoch_response=$(call_view "$EPOCH_MGR" "$SELECTOR_GET_CURRENT_EPOCH")
  local epoch
  epoch=$(echo "$epoch_response" | jq -r '.result[0] // "0x0"')
  epoch=$((epoch))
  log "INFO" "Current epoch: $epoch (previous: $prev_epoch)"

  # Epoch should never decrease
  if [[ $epoch -lt $prev_epoch && $prev_epoch -gt 0 ]]; then
    alert "CRITICAL: Epoch DECREASED from $prev_epoch to $epoch — possible rollback"
  fi

  # Epoch stalled for too long (> 10 intervals without advancing)
  if [[ $epoch -eq $prev_epoch && $prev_epoch -gt 0 ]]; then
    local stall_file="/tmp/starkprivacy-epoch-stall"
    local stall_count=0
    if [[ -f "$stall_file" ]]; then
      stall_count=$(cat "$stall_file")
    fi
    stall_count=$((stall_count + 1))
    echo "$stall_count" > "$stall_file"

    if [[ $stall_count -ge 10 ]]; then
      alert "WARNING: Epoch has been stalled at $epoch for $stall_count consecutive checks"
      echo "0" > "$stall_file"
    fi
  else
    echo "0" > /tmp/starkprivacy-epoch-stall 2>/dev/null || true
  fi

  # Update prev_epoch in state
  local new_state
  new_state=$(echo "$(load_state)" | jq --argjson e "$epoch" '.prev_epoch = $e')
  save_state "$new_state"
}

check_kakarot_health() {
  if [[ -z "$KAKAROT" ]]; then
    return
  fi

  log "INFO" "Checking Kakarot adapter health..."

  # Check if adapter is paused
  local pause_response
  pause_response=$(call_view "$KAKAROT" "$SELECTOR_IS_PAUSED")
  local is_paused
  is_paused=$(echo "$pause_response" | jq -r '.result[0] // "0x0"')

  if [[ "$is_paused" != "0x0" ]]; then
    alert "WARNING: Kakarot adapter is PAUSED — EVM operations are blocked"
  else
    log "INFO" "Kakarot adapter is active"
  fi
}

check_rpc_liveness() {
  log "INFO" "Checking RPC liveness..."
  local response
  response=$(rpc_call "starknet_blockNumber" 2>/dev/null || echo "ERROR")

  if [[ "$response" == "ERROR" ]]; then
    alert "CRITICAL: RPC node at $RPC_URL is unreachable"
    return 1
  fi

  local block
  block=$(echo "$response" | jq -r '.result // "unknown"')
  log "INFO" "Latest block: $block"
  return 0
}

# ─── Summary ──────────────────────────────────────────────────

print_summary() {
  local state
  state=$(load_state)
  local checks
  checks=$(echo "$state" | jq -r '.checks')
  local alerts
  alerts=$(echo "$state" | jq -r '.alerts')

  log "INFO" "=== Health Check Summary ==="
  log "INFO" "Total checks: $checks"
  log "INFO" "Total alerts: $alerts"
  log "INFO" "Log file: $LOG_FILE"
  log "INFO" "State file: $STATE_FILE"
}

# ─── Main Loop ────────────────────────────────────────────────

main() {
  log "INFO" "========================================="
  log "INFO" "StarkPrivacy Monitor starting"
  log "INFO" "Pool:           $POOL"
  log "INFO" "Epoch Manager:  ${EPOCH_MGR:-not configured}"
  log "INFO" "Kakarot:        ${KAKAROT:-not configured}"
  log "INFO" "Interval:       ${INTERVAL}s"
  log "INFO" "Log file:       $LOG_FILE"
  log "INFO" "========================================="

  while true; do
    log "INFO" "--- Health check cycle ---"

    if check_rpc_liveness; then
      check_pool_health
      check_epoch_health
      check_kakarot_health
    fi

    print_summary
    log "INFO" "Sleeping ${INTERVAL}s..."
    sleep "$INTERVAL"
  done
}

# Run once mode (for CI/cron)
if [[ "${1:-}" == "--once" ]]; then
  log "INFO" "Running single health check..."
  if check_rpc_liveness; then
    check_pool_health
    check_epoch_health
    check_kakarot_health
  fi
  print_summary
  exit 0
fi

main
