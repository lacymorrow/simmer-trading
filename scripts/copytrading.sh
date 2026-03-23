#!/usr/bin/env bash
set -euo pipefail

# copytrading.sh - Mirror positions from high-performing whale wallets
# Cron-compatible: runs once, logs signals, exits
#
# Strategy:
#   Uses Simmer's /copytrading/execute endpoint to:
#   1. Fetch positions from target wallets
#   2. Calculate size-weighted allocations
#   3. Execute rebalance trades (buy-only by default)
#
# Usage: ./copytrading.sh
# Cron:  0 */4 * * * SIMMER_API_KEY=sk_live_... /path/to/copytrading.sh >> /tmp/copytrading.log 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMMER="${SCRIPT_DIR}/simmer.sh"

# --- Configuration (override via env) ---
DRY_RUN="${DRY_RUN:-true}"
VENUE="${VENUE:-sim}"
MAX_USD_PER_POSITION="${MAX_USD_PER_POSITION:-50}"
TOP_N="${TOP_N:-10}"                                  # Number of positions to mirror (null = auto)
BUY_ONLY="${BUY_ONLY:-true}"                          # Only buy, don't sell other strategies' positions
DETECT_WHALE_EXITS="${DETECT_WHALE_EXITS:-true}"      # Sell when whales exit

# Target wallets to copy (comma-separated or newline-separated)
# Override via COPY_WALLETS env var
COPY_WALLETS="${COPY_WALLETS:-}"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

log "=== Copytrading starting (dry_run=$DRY_RUN, venue=$VENUE, max_usd=$MAX_USD_PER_POSITION, top_n=$TOP_N) ==="

if [[ -z "$COPY_WALLETS" ]]; then
  log "ERROR: COPY_WALLETS is not set. Provide comma-separated wallet addresses."
  log "Example: export COPY_WALLETS=\"0xabc...,0xdef...\""
  exit 1
fi

# Convert to JSON array
WALLETS_JSON=$(echo "$COPY_WALLETS" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | jq -R . | jq -s .)
WALLET_COUNT=$(echo "$WALLETS_JSON" | jq 'length')
log "Copying from $WALLET_COUNT wallets"

# Build request body
BODY=$(jq -n \
  --argjson wallets "$WALLETS_JSON" \
  --argjson top_n "$TOP_N" \
  --argjson max_usd_per_position "$MAX_USD_PER_POSITION" \
  --argjson dry_run "$([ "$DRY_RUN" = "true" ] && echo true || echo false)" \
  --argjson buy_only "$([ "$BUY_ONLY" = "true" ] && echo true || echo false)" \
  --argjson detect_whale_exits "$([ "$DETECT_WHALE_EXITS" = "true" ] && echo true || echo false)" \
  --arg venue "$VENUE" \
  '{
    wallets: $wallets,
    top_n: $top_n,
    max_usd_per_position: $max_usd_per_position,
    dry_run: $dry_run,
    buy_only: $buy_only,
    detect_whale_exits: $detect_whale_exits,
    venue: $venue
  }')

log "Executing copytrading..."
RESULT=$("$SIMMER" POST /api/sdk/copytrading/execute "$BODY" 2>/dev/null) || {
  log "ERROR: Copytrading request failed"
  exit 1
}

# Log results
SIGNALS_COUNT=$(echo "$RESULT" | jq '.signals | length' 2>/dev/null || echo 0)
TRADES_COUNT=$(echo "$RESULT" | jq '.trades_executed | length' 2>/dev/null || echo 0)
SKIPPED_COUNT=$(echo "$RESULT" | jq '.skipped | length' 2>/dev/null || echo 0)

log "Signals: $SIGNALS_COUNT, Trades executed: $TRADES_COUNT, Skipped: $SKIPPED_COUNT"

# Log each signal
if [[ "$SIGNALS_COUNT" -gt 0 ]]; then
  log "--- Signals ---"
  echo "$RESULT" | jq -c '.signals[]?' 2>/dev/null | while IFS= read -r signal; do
    MARKET=$(echo "$signal" | jq -r '.market_question // .market_id // "unknown"')
    SIDE=$(echo "$signal" | jq -r '.side // "unknown"')
    AMOUNT=$(echo "$signal" | jq -r '.amount // 0')
    log "  Signal: $SIDE on '$MARKET' for \$$AMOUNT"
  done
fi

# Log executed trades
if [[ "$TRADES_COUNT" -gt 0 ]]; then
  log "--- Trades ---"
  echo "$RESULT" | jq -c '.trades_executed[]?' 2>/dev/null | while IFS= read -r trade; do
    MARKET=$(echo "$trade" | jq -r '.market_question // .market_id // "unknown"')
    SIDE=$(echo "$trade" | jq -r '.side // "unknown"')
    SHARES=$(echo "$trade" | jq -r '.shares_bought // .shares // 0')
    log "  Traded: $SIDE on '$MARKET' ($SHARES shares)"
  done
fi

# Log skipped
if [[ "$SKIPPED_COUNT" -gt 0 ]]; then
  log "--- Skipped ---"
  echo "$RESULT" | jq -c '.skipped[]?' 2>/dev/null | while IFS= read -r skip; do
    REASON=$(echo "$skip" | jq -r '.reason // "unknown"')
    MARKET=$(echo "$skip" | jq -r '.market_question // .market_id // "unknown"')
    log "  Skipped '$MARKET': $REASON"
  done
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "NOTE: This was a dry run. Set DRY_RUN=false to execute real trades."
fi

log "=== Copytrading finished ==="
