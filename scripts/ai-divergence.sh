#!/usr/bin/env bash
set -euo pipefail

# ai-divergence.sh - Trade markets where AI price diverges from market price
# Cron-compatible: runs once, logs reasoning, exits
#
# Strategy:
#   1. Call /api/sdk/markets/opportunities to find mispriced markets
#   2. Filter by minimum divergence threshold
#   3. Get context for each opportunity before trading
#   4. Place trades on highest-edge opportunities
#
# Usage: ./ai-divergence.sh
# Cron:  0 */2 * * * SIMMER_API_KEY=sk_live_... /path/to/ai-divergence.sh >> /tmp/ai-divergence.log 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMMER="${SCRIPT_DIR}/simmer.sh"

# --- Configuration (override via env) ---
DRY_RUN="${DRY_RUN:-true}"
MIN_DIVERGENCE="${MIN_DIVERGENCE:-0.05}"    # 5% minimum divergence
TRADE_AMOUNT="${TRADE_AMOUNT:-10}"          # USD per trade
VENUE="${VENUE:-sim}"                       # sim or polymarket
MAX_TRADES="${MAX_TRADES:-5}"               # Max trades per run
OPPORTUNITY_LIMIT="${OPPORTUNITY_LIMIT:-20}" # Number of opportunities to fetch
SOURCE="sdk:ai-divergence"
SKILL_SLUG="simmer-ai-divergence"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

log "=== AI Divergence Trader starting (dry_run=$DRY_RUN, min_divergence=$MIN_DIVERGENCE, venue=$VENUE) ==="

# Step 1: Fetch opportunities
log "Fetching opportunities (min_divergence=$MIN_DIVERGENCE)..."
OPPORTUNITIES=$("$SIMMER" GET "/api/sdk/markets/opportunities?limit=${OPPORTUNITY_LIMIT}&min_divergence=${MIN_DIVERGENCE}" 2>/dev/null) || {
  log "ERROR: Failed to fetch opportunities"
  exit 1
}

OPP_COUNT=$(echo "$OPPORTUNITIES" | jq '.markets | length' 2>/dev/null || echo 0)
log "Found $OPP_COUNT opportunities above ${MIN_DIVERGENCE} divergence"

if [[ "$OPP_COUNT" -eq 0 ]]; then
  log "No opportunities found. Exiting."
  exit 0
fi

# Step 2: Process each opportunity (sorted by divergence, highest first)
TRADES_PLACED=0

echo "$OPPORTUNITIES" | jq -c '.markets[]' 2>/dev/null | while IFS= read -r opp; do
  if [[ "$TRADES_PLACED" -ge "$MAX_TRADES" ]]; then
    log "Max trades reached ($MAX_TRADES). Stopping."
    break
  fi

  MARKET_ID=$(echo "$opp" | jq -r '.id // .market_id')
  QUESTION=$(echo "$opp" | jq -r '.question')
  DIVERGENCE=$(echo "$opp" | jq -r '.divergence // 0')
  RECOMMENDED_SIDE=$(echo "$opp" | jq -r '.recommended_side // "yes"')
  SIGNAL_SOURCE=$(echo "$opp" | jq -r '.signal_source // "unknown"')
  MARKET_PRICE=$(echo "$opp" | jq -r '.current_probability // .yes_price // 0')
  AI_PRICE=$(echo "$opp" | jq -r '.ai_probability // .simmer_price // 0')

  log "--- Opportunity: $QUESTION ---"
  log "  Divergence: $DIVERGENCE, Signal: $SIGNAL_SOURCE, Side: $RECOMMENDED_SIDE"
  log "  Market price: $MARKET_PRICE, AI price: $AI_PRICE"

  # Step 3: Get context before trading
  CONTEXT=$("$SIMMER" GET "/api/sdk/context/${MARKET_ID}" 2>/dev/null) || {
    log "WARN: Failed to get context for $MARKET_ID, skipping"
    continue
  }

  # Check for warnings
  WARNINGS=$(echo "$CONTEXT" | jq -r '.warnings // [] | join(", ")' 2>/dev/null)
  if [[ -n "$WARNINGS" && "$WARNINGS" != "" ]]; then
    log "  Warnings: $WARNINGS"
  fi

  # Check if we already hold a position
  HAS_POSITION=$(echo "$CONTEXT" | jq -r '.position.shares // 0' 2>/dev/null)
  if [[ "$HAS_POSITION" != "0" && "$HAS_POSITION" != "null" ]]; then
    log "  Already holding position ($HAS_POSITION shares), skipping"
    continue
  fi

  # Check context recommendation
  CTX_RECOMMENDATION=$(echo "$CONTEXT" | jq -r '.edge_analysis.recommendation // "NONE"' 2>/dev/null)
  if [[ "$CTX_RECOMMENDATION" == "HOLD" || "$CTX_RECOMMENDATION" == "NONE" ]]; then
    log "  Context recommends $CTX_RECOMMENDATION despite divergence, skipping"
    continue
  fi

  REASONING="AI divergence trade: $SIGNAL_SOURCE signal shows $DIVERGENCE divergence. AI probability $AI_PRICE vs market $MARKET_PRICE. Recommended: $RECOMMENDED_SIDE."

  # Step 4: Place trade
  if [[ "$DRY_RUN" == "true" ]]; then
    log "  DRY RUN: Would trade $RECOMMENDED_SIDE for \$$TRADE_AMOUNT"
    log "  Reasoning: $REASONING"
  else
    log "  Placing trade: $RECOMMENDED_SIDE for \$$TRADE_AMOUNT"
    TRADE_BODY=$(jq -n \
      --arg market_id "$MARKET_ID" \
      --arg side "$RECOMMENDED_SIDE" \
      --argjson amount "$TRADE_AMOUNT" \
      --arg venue "$VENUE" \
      --arg source "$SOURCE" \
      --arg skill_slug "$SKILL_SLUG" \
      --arg reasoning "$REASONING" \
      '{market_id: $market_id, side: $side, amount: $amount, venue: $venue, source: $source, skill_slug: $skill_slug, reasoning: $reasoning}')

    RESULT=$("$SIMMER" POST /api/sdk/trade "$TRADE_BODY" 2>/dev/null) || {
      log "  ERROR: Trade failed"
      continue
    }

    SHARES=$(echo "$RESULT" | jq -r '.shares_bought // .shares // "unknown"')
    log "  Trade executed: $SHARES shares"
  fi

  TRADES_PLACED=$((TRADES_PLACED + 1))
done

log "=== AI Divergence Trader finished (trades: $TRADES_PLACED) ==="
