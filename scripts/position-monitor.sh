#!/usr/bin/env bash
set -euo pipefail

# position-monitor.sh - Monitor open positions and manage exits
# Cron-compatible: runs once, exits
#
# Actions:
#   1. Check all open positions
#   2. Sell if take-profit or stop-loss hit (backup to Simmer's built-in monitors)
#   3. Sell if market is about to resolve and we're losing
#   4. Log P&L summary
#
# Usage: ./position-monitor.sh
# Cron:  */5 * * * * SIMMER_API_KEY=sk_live_... /path/to/position-monitor.sh >> /tmp/position-monitor.log 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMMER="${SCRIPT_DIR}/simmer.sh"

# --- Configuration ---
DRY_RUN="${DRY_RUN:-true}"
STOP_LOSS_PCT="${STOP_LOSS_PCT:-0.30}"         # -30% loss = sell
TAKE_PROFIT_PCT="${TAKE_PROFIT_PCT:-1.00}"     # +100% profit = sell
CLOSE_BEFORE_MINS="${CLOSE_BEFORE_MINS:-30}"   # Sell losing positions this many minutes before resolution
MIN_SHARES_TO_SELL="${MIN_SHARES_TO_SELL:-5}"   # Polymarket minimum

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

log "=== Position Monitor starting (dry_run=$DRY_RUN) ==="

# Fetch positions
POSITIONS=$("$SIMMER" GET /api/sdk/positions 2>/dev/null) || {
  log "ERROR: Failed to fetch positions"
  exit 1
}

POS_COUNT=$(echo "$POSITIONS" | jq '.positions | length' 2>/dev/null || echo 0)
log "Open positions: $POS_COUNT"

if [[ "$POS_COUNT" -eq 0 ]]; then
  log "No positions. Exiting."
  exit 0
fi

# Summary
TOTAL_VALUE=$(echo "$POSITIONS" | jq '[.positions[].current_value] | add' 2>/dev/null || echo 0)
TOTAL_COST=$(echo "$POSITIONS" | jq '[.positions[].cost_basis] | add' 2>/dev/null || echo 0)
TOTAL_PNL=$(echo "$POSITIONS" | jq '[.positions[].pnl] | add' 2>/dev/null || echo 0)
log "Portfolio: value=\$$TOTAL_VALUE, cost=\$$TOTAL_COST, P&L=\$$TOTAL_PNL"

NOW_EPOCH=$(date +%s)

echo "$POSITIONS" | jq -c '.positions[]' 2>/dev/null | while IFS= read -r pos; do
  MARKET_ID=$(echo "$pos" | jq -r '.market_id')
  QUESTION=$(echo "$pos" | jq -r '.question')
  SHARES_YES=$(echo "$pos" | jq -r '.shares_yes // 0')
  SHARES_NO=$(echo "$pos" | jq -r '.shares_no // 0')
  COST_BASIS=$(echo "$pos" | jq -r '.cost_basis // 0')
  CURRENT_VALUE=$(echo "$pos" | jq -r '.current_value // 0')
  PNL=$(echo "$pos" | jq -r '.pnl // 0')
  STATUS=$(echo "$pos" | jq -r '.status // "unknown"')
  VENUE=$(echo "$pos" | jq -r '.venue // "sim"')
  RESOLVES_AT=$(echo "$pos" | jq -r '.resolves_at // ""')

  # Determine side and shares
  if echo "$SHARES_YES" | awk '{exit ($1 > 0) ? 0 : 1}'; then
    SIDE="yes"
    SHARES="$SHARES_YES"
  else
    SIDE="no"
    SHARES="$SHARES_NO"
  fi

  # Calculate P&L percentage
  PNL_PCT=$(echo "$PNL $COST_BASIS" | awk '{if($2>0) printf "%.1f", ($1/$2)*100; else print "0"}')

  log "--- $QUESTION ---"
  log "  Side: $SIDE, shares: $SHARES, cost: \$$COST_BASIS, value: \$$CURRENT_VALUE, P&L: \$$PNL (${PNL_PCT}%)"

  # Check if resolved
  if [[ "$STATUS" == "resolved" ]]; then
    OUTCOME=$(echo "$pos" | jq -r '.outcome // "unknown"')
    REDEEMABLE=$(echo "$pos" | jq -r '.redeemable // false')
    log "  RESOLVED: outcome=$OUTCOME, redeemable=$REDEEMABLE"
    if [[ "$REDEEMABLE" == "true" ]]; then
      log "  Auto-redeem is enabled, Simmer will handle redemption"
    fi
    continue
  fi

  ACTION="hold"
  REASON=""

  # Check stop-loss
  IS_STOP=$(echo "$PNL_PCT $STOP_LOSS_PCT" | awk '{print ($1 < -($2*100)) ? "yes" : "no"}')
  if [[ "$IS_STOP" == "yes" ]]; then
    ACTION="sell"
    REASON="Stop-loss hit: ${PNL_PCT}% < -${STOP_LOSS_PCT}%"
  fi

  # Check take-profit
  IS_PROFIT=$(echo "$PNL_PCT $TAKE_PROFIT_PCT" | awk '{print ($1 > ($2*100)) ? "yes" : "no"}')
  if [[ "$IS_PROFIT" == "yes" ]]; then
    ACTION="sell"
    REASON="Take-profit hit: ${PNL_PCT}% > +${TAKE_PROFIT_PCT}%"
  fi

  # Check if close to resolution and losing
  if [[ -n "$RESOLVES_AT" && "$RESOLVES_AT" != "null" ]]; then
    # Parse resolve time (handle various formats)
    RESOLVE_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${RESOLVES_AT%%+*}" "+%s" 2>/dev/null || \
                    date -j -f "%Y-%m-%d %H:%M:%S" "${RESOLVES_AT%%+*}" "+%s" 2>/dev/null || \
                    echo "0")
    if [[ "$RESOLVE_EPOCH" -gt 0 ]]; then
      MINS_LEFT=$(( (RESOLVE_EPOCH - NOW_EPOCH) / 60 ))
      log "  Resolves in ${MINS_LEFT} minutes"

      IS_LOSING=$(echo "$PNL" | awk '{print ($1 < 0) ? "yes" : "no"}')
      if [[ "$MINS_LEFT" -le "$CLOSE_BEFORE_MINS" && "$IS_LOSING" == "yes" && "$ACTION" == "hold" ]]; then
        ACTION="sell"
        REASON="Closing losing position ${MINS_LEFT}min before resolution (P&L: ${PNL_PCT}%)"
      fi
    fi
  fi

  if [[ "$ACTION" == "sell" ]]; then
    # Check minimum shares
    ENOUGH_SHARES=$(echo "$SHARES $MIN_SHARES_TO_SELL" | awk '{print ($1 >= $2) ? "yes" : "no"}')
    if [[ "$ENOUGH_SHARES" != "yes" ]]; then
      log "  Would sell but shares ($SHARES) below minimum ($MIN_SHARES_TO_SELL)"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log "  DRY RUN: Would sell $SHARES shares ($SIDE). Reason: $REASON"
    else
      log "  SELLING: $SHARES shares ($SIDE). Reason: $REASON"
      SELL_BODY=$(jq -n \
        --arg market_id "$MARKET_ID" \
        --arg side "$SIDE" \
        --arg action "sell" \
        --argjson shares "$SHARES" \
        --arg venue "$VENUE" \
        --arg source "sdk:position-monitor" \
        --arg reasoning "$REASON" \
        '{market_id: $market_id, side: $side, action: $action, shares: $shares, venue: $venue, source: $source, reasoning: $reasoning}')

      RESULT=$("$SIMMER" POST /api/sdk/trade "$SELL_BODY" 2>/dev/null) || {
        log "  ERROR: Sell failed"
        continue
      }
      SOLD=$(echo "$RESULT" | jq -r '.shares_sold // .shares // "unknown"')
      log "  Sold $SOLD shares"
    fi
  else
    log "  Action: HOLD"
  fi
done

log "=== Position Monitor finished ==="
