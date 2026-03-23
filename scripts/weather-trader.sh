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
EDGE_THRESHOLD="${EDGE_THRESHOLD:-0.10}"       # Min edge to trade (10%)
TRADE_AMOUNT="${TRADE_AMOUNT:-10}"              # USD per trade
VENUE="${VENUE:-sim}"                           # sim or polymarket
MAX_TRADES="${MAX_TRADES:-5}"                   # Max trades per run
SOURCE="sdk:weather-trader"
SKILL_SLUG="simmer-weather-trader"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

log "=== Weather Trader starting (dry_run=$DRY_RUN, edge_threshold=$EDGE_THRESHOLD, venue=$VENUE) ==="

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

  # Check for warnings
  WARNINGS=$(echo "$CONTEXT" | jq -r '.warnings // [] | join(", ")' 2>/dev/null)
  if [[ -n "$WARNINGS" && "$WARNINGS" != "" ]]; then
    log "WARN: $WARNINGS"
  fi

  # Check if we already hold a position
  HAS_POSITION=$(echo "$CONTEXT" | jq -r '.position.shares // 0' 2>/dev/null)
  if [[ "$HAS_POSITION" != "0" && "$HAS_POSITION" != "null" ]]; then
    log "Already holding position ($HAS_POSITION shares), skipping"
    continue
  fi

  # Step 4: Extract location info from question for NOAA lookup
  # Try to extract city/state from the question text
  # Common patterns: "temperature in NYC", "weather in Chicago", etc.
  # For now, use the Simmer AI divergence as the signal
  DIVERGENCE=$(echo "$CONTEXT" | jq -r '.edge_analysis.divergence // 0' 2>/dev/null)
  RECOMMENDATION=$(echo "$CONTEXT" | jq -r '.edge_analysis.recommendation // "HOLD"' 2>/dev/null)
  AI_PRICE=$(echo "$CONTEXT" | jq -r '.edge_analysis.ai_probability // 0' 2>/dev/null)

  # Calculate edge (absolute divergence)
  if command -v bc &>/dev/null; then
    EDGE=$(echo "scale=4; x=$DIVERGENCE; if (x < 0) -x else x" | bc 2>/dev/null || echo "0")
  else
    # Fallback: use awk for abs
    EDGE=$(echo "$DIVERGENCE" | awk '{x=$1; if(x<0) x=-x; printf "%.4f", x}')
  fi

  log "Edge: $EDGE (threshold: $EDGE_THRESHOLD), AI price: $AI_PRICE, recommendation: $RECOMMENDATION"

  # Step 5: Trade if edge exceeds threshold
  SHOULD_TRADE=$(echo "$EDGE $EDGE_THRESHOLD" | awk '{print ($1 >= $2) ? "yes" : "no"}')

  if [[ "$SHOULD_TRADE" != "yes" ]]; then
    log "Edge too small ($EDGE < $EDGE_THRESHOLD), skipping"
    continue
  fi

  # Determine side based on divergence direction
  if echo "$DIVERGENCE" | awk '{exit ($1 > 0) ? 0 : 1}'; then
    SIDE="yes"
  else
    SIDE="no"
  fi

  REASONING="Weather market edge: AI probability $AI_PRICE vs market price $CURRENT_PRICE (divergence: $DIVERGENCE). Edge $EDGE exceeds threshold $EDGE_THRESHOLD."

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
