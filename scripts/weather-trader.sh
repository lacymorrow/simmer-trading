#!/usr/bin/env bash
set -euo pipefail

# weather-trader.sh - Trade weather prediction markets using NOAA forecast data
# Cron-compatible: runs once, logs reasoning, exits
#
# Strategy:
#   1. Fetch weather-tagged markets from Simmer
#   2. Get NOAA forecast data for relevant locations
#   3. Compare forecast probability vs market price
#   4. Trade when edge exceeds threshold
#
# Usage: ./weather-trader.sh
# Cron:  */30 * * * * SIMMER_API_KEY=sk_live_... /path/to/weather-trader.sh >> /tmp/weather-trader.log 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMMER="${SCRIPT_DIR}/simmer.sh"

# --- Configuration (override via env) ---
DRY_RUN="${DRY_RUN:-true}"
ENTRY_THRESHOLD="${ENTRY_THRESHOLD:-0.15}"      # Buy below this price (15%)
EXIT_THRESHOLD="${EXIT_THRESHOLD:-0.45}"        # Sell above this price (45%)
EDGE_PCT_THRESHOLD="${EDGE_PCT_THRESHOLD:-15}"  # Min RELATIVE edge to trade (15% of market price)
MIN_PRICE="${MIN_PRICE:-0.01}"                  # Skip markets priced below this (too illiquid)
MAX_SPREAD_PCT="${MAX_SPREAD_PCT:-50}"          # Skip markets with spread wider than this %
TRADE_AMOUNT="${TRADE_AMOUNT:-2}"               # USD per trade ($2 max position per article)
VENUE="${VENUE:-sim}"                           # sim or polymarket
MAX_TRADES="${MAX_TRADES:-5}"                   # Max trades per run
LOCATIONS="${LOCATIONS:-NYC,Chicago,Seattle,Atlanta,Dallas,Miami}"
SOURCE="sdk:weather-trader"
SKILL_SLUG="simmer-weather-trader"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

log "=== Weather Trader starting (dry_run=$DRY_RUN, edge_pct=$EDGE_PCT_THRESHOLD%, min_price=$MIN_PRICE, venue=$VENUE) ==="

# Step 1: Fetch weather markets
log "Fetching weather markets..."
MARKETS=$("$SIMMER" GET "/api/sdk/markets?tags=weather&status=active&limit=20" 2>/dev/null) || {
  log "ERROR: Failed to fetch markets"
  exit 1
}

MARKET_COUNT=$(echo "$MARKETS" | jq '.markets | length' 2>/dev/null || echo 0)
log "Found $MARKET_COUNT weather markets"

if [[ "$MARKET_COUNT" -eq 0 ]]; then
  log "No weather markets found. Exiting."
  exit 0
fi

# Step 2: Process each market
TRADES_PLACED=0

echo "$MARKETS" | jq -c '.markets[]' 2>/dev/null | while IFS= read -r market; do
  if [[ "$TRADES_PLACED" -ge "$MAX_TRADES" ]]; then
    log "Max trades reached ($MAX_TRADES). Stopping."
    break
  fi

  MARKET_ID=$(echo "$market" | jq -r '.id')
  QUESTION=$(echo "$market" | jq -r '.question')
  CURRENT_PRICE=$(echo "$market" | jq -r '.current_probability // .yes_price // 0')

  log "--- Evaluating: $QUESTION (price=$CURRENT_PRICE) ---"

  # Step 3: Get context for edge analysis
  CONTEXT=$("$SIMMER" GET "/api/sdk/context/${MARKET_ID}" 2>/dev/null) || {
    log "WARN: Failed to get context for $MARKET_ID, skipping"
    continue
  }

  # Pre-filter: skip sub-penny markets (too illiquid for real trading)
  PRICE_OK=$(echo "$CURRENT_PRICE $MIN_PRICE" | awk '{print ($1 >= $2) ? "yes" : "no"}')
  if [[ "$PRICE_OK" != "yes" ]]; then
    log "  Price too low ($CURRENT_PRICE < $MIN_PRICE), skipping"
    continue
  fi

  # Check spread from market data
  SPREAD_PCT=$(echo "$market" | jq -r '.spread // 0' 2>/dev/null)
  # If no spread in market list, we'll check in context

  # Rate limit: context endpoint is 20/min, add delay
  sleep 3

  # Check for warnings
  WARNINGS=$(echo "$CONTEXT" | jq -r '.warnings // [] | join(", ")' 2>/dev/null)
  if [[ -n "$WARNINGS" && "$WARNINGS" != "" ]]; then
    log "  WARN: $WARNINGS"
  fi

  # Check spread from context
  CTX_SPREAD=$(echo "$CONTEXT" | jq -r '.slippage.spread_pct // 0' 2>/dev/null)
  SPREAD_TOO_WIDE=$(echo "$CTX_SPREAD $MAX_SPREAD_PCT" | awk '{print ($1 > $2) ? "yes" : "no"}')
  if [[ "$SPREAD_TOO_WIDE" == "yes" ]]; then
    log "  Spread too wide (${CTX_SPREAD}% > ${MAX_SPREAD_PCT}%), skipping"
    continue
  fi

  # Check if we already hold a position
  HAS_POSITION=$(echo "$CONTEXT" | jq -r '.position.shares // 0' 2>/dev/null)
  IS_HOLDING=$(echo "$HAS_POSITION" | awk '{print ($1 > 0) ? "yes" : "no"}')
  if [[ "$IS_HOLDING" == "yes" ]]; then
    log "  Already holding position ($HAS_POSITION shares), skipping"
    continue
  fi

  # Use Simmer's built-in AI consensus and edge analysis
  DIVERGENCE=$(echo "$CONTEXT" | jq -r '.market.divergence // .edge.user_edge // 0' 2>/dev/null)
  RECOMMENDATION=$(echo "$CONTEXT" | jq -r '.edge.recommendation // "HOLD"' 2>/dev/null)
  AI_PRICE=$(echo "$CONTEXT" | jq -r '.market.ai_consensus // 0' 2>/dev/null)

  # Calculate RELATIVE edge: |divergence| / market_price * 100
  ABS_DIVERGENCE=$(echo "$DIVERGENCE" | awk '{x=$1; if(x<0) x=-x; print x}')
  EDGE_PCT=$(echo "$ABS_DIVERGENCE $CURRENT_PRICE" | awk '{if($2>0) printf "%.1f", ($1/$2)*100; else print "0"}')

  log "  Edge: ${EDGE_PCT}% (threshold: ${EDGE_PCT_THRESHOLD}%), divergence: $ABS_DIVERGENCE, AI: $AI_PRICE, rec: $RECOMMENDATION, spread: ${CTX_SPREAD}%"

  # Trade if relative edge exceeds threshold
  SHOULD_TRADE=$(echo "$EDGE_PCT $EDGE_PCT_THRESHOLD" | awk '{print ($1 >= $2) ? "yes" : "no"}')

  if [[ "$SHOULD_TRADE" != "yes" ]]; then
    log "  Edge too small (${EDGE_PCT}% < ${EDGE_PCT_THRESHOLD}%), skipping"
    continue
  fi

  # Determine side based on divergence direction
  if echo "$DIVERGENCE" | awk '{exit ($1 > 0) ? 0 : 1}'; then
    SIDE="yes"
  else
    SIDE="no"
  fi

  REASONING="Weather market edge: AI probability $AI_PRICE vs market price $CURRENT_PRICE (divergence: $DIVERGENCE, relative edge: ${EDGE_PCT}%). Spread: ${CTX_SPREAD}%."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN: Would trade $SIDE on '$QUESTION' for \$$TRADE_AMOUNT"
    log "  Reasoning: $REASONING"
  else
    log "Placing trade: $SIDE on '$QUESTION' for \$$TRADE_AMOUNT"
    TRADE_BODY=$(jq -n \
      --arg market_id "$MARKET_ID" \
      --arg side "$SIDE" \
      --argjson amount "$TRADE_AMOUNT" \
      --arg venue "$VENUE" \
      --arg source "$SOURCE" \
      --arg skill_slug "$SKILL_SLUG" \
      --arg reasoning "$REASONING" \
      '{market_id: $market_id, side: $side, amount: $amount, venue: $venue, source: $source, skill_slug: $skill_slug, reasoning: $reasoning}')

    RESULT=$("$SIMMER" POST /api/sdk/trade "$TRADE_BODY" 2>/dev/null) || {
      log "ERROR: Trade failed for $MARKET_ID"
      continue
    }

    SHARES=$(echo "$RESULT" | jq -r '.shares_bought // .shares // "unknown"')
    log "Trade executed: $SHARES shares of $SIDE"
  fi

  TRADES_PLACED=$((TRADES_PLACED + 1))
done

log "=== Weather Trader finished (trades: $TRADES_PLACED) ==="
