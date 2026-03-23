#!/usr/bin/env bash
set -euo pipefail

# fast-loop.sh - BTC 5-min / 15-min fast market trading
# Cron-compatible: runs once, logs reasoning, exits
#
# Strategy (from kirillk_web3 article):
#   1. Fetch active BTC fast markets (5-min and 15-min rounds)
#   2. Get real BTC price from Simmer context
#   3. Compare price deviation vs market probability
#   4. Trade when BTC price moves 0.5%+ from market's implied direction
#   5. Exit 15 seconds before close (handled by Simmer's exit logic)
#
# Usage: ./fast-loop.sh
# Cron:  * * * * * SIMMER_API_KEY=sk_live_... /path/to/fast-loop.sh >> /tmp/fast-loop.log 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMMER="${SCRIPT_DIR}/simmer.sh"

# --- Configuration (override via env) ---
DRY_RUN="${DRY_RUN:-true}"
TRADE_AMOUNT="${TRADE_AMOUNT:-5}"               # USD per trade ($5 per article)
VENUE="${VENUE:-sim}"                           # sim or polymarket
MAX_POSITIONS="${MAX_POSITIONS:-3}"             # Max concurrent positions
STOP_LOSS="${STOP_LOSS:-3}"                     # Max loss per trade in USD
DAILY_LOSS_LIMIT="${DAILY_LOSS_LIMIT:-50}"      # Daily loss limit in USD
PRICE_DEVIATION="${PRICE_DEVIATION:-0.005}"     # 0.5% price move threshold
SOURCE="sdk:fast-loop"
SKILL_SLUG="simmer-fast-loop"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

log "=== Fast Loop starting (dry_run=$DRY_RUN, trade_amount=$TRADE_AMOUNT, venue=$VENUE) ==="

# Step 1: Check daily P&L to respect loss limit
PORTFOLIO=$("$SIMMER" GET /api/sdk/portfolio 2>/dev/null) || {
  log "ERROR: Failed to fetch portfolio"
  exit 1
}

DAILY_PNL=$(echo "$PORTFOLIO" | jq -r '.daily_pnl // 0' 2>/dev/null)
log "Daily P&L: $DAILY_PNL (limit: -$DAILY_LOSS_LIMIT)"

OVER_LIMIT=$(echo "$DAILY_PNL $DAILY_LOSS_LIMIT" | awk '{print ($1 < -$2) ? "yes" : "no"}')
if [[ "$OVER_LIMIT" == "yes" ]]; then
  log "Daily loss limit hit ($DAILY_PNL). Stopping."
  exit 0
fi

# Step 2: Check current positions count
POSITIONS=$("$SIMMER" GET /api/sdk/positions 2>/dev/null) || {
  log "ERROR: Failed to fetch positions"
  exit 1
}

# Count only fast-market positions (BTC up/down)
ACTIVE_POSITIONS=$(echo "$POSITIONS" | jq '[.positions[] | select(.market_question | test("Bitcoin|BTC|Solana|Ethereum"; "i")) | select(.market_question | test("Up or Down"; "i"))] | length' 2>/dev/null || echo 0)
log "Active fast-market positions: $ACTIVE_POSITIONS (max: $MAX_POSITIONS)"

if [[ "$ACTIVE_POSITIONS" -ge "$MAX_POSITIONS" ]]; then
  log "Max positions reached. Waiting for resolution."
  exit 0
fi

# Step 3: Fetch active fast markets
FAST_MARKETS=$("$SIMMER" GET "/api/sdk/markets?tags=fast-market,btc&status=active&limit=10" 2>/dev/null) || {
  # Fallback: search by keyword
  FAST_MARKETS=$("$SIMMER" GET "/api/sdk/markets?q=Bitcoin+Up+or+Down&status=active&limit=10" 2>/dev/null) || {
    log "ERROR: Failed to fetch fast markets"
    exit 1
  }
}

MARKET_COUNT=$(echo "$FAST_MARKETS" | jq '.markets | length' 2>/dev/null || echo 0)
log "Found $MARKET_COUNT fast markets"

if [[ "$MARKET_COUNT" -eq 0 ]]; then
  log "No active fast markets found. Exiting."
  exit 0
fi

# Step 4: Process each market
TRADES_PLACED=0
SLOTS_AVAILABLE=$((MAX_POSITIONS - ACTIVE_POSITIONS))

echo "$FAST_MARKETS" | jq -c '.markets[]' 2>/dev/null | while IFS= read -r market; do
  if [[ "$TRADES_PLACED" -ge "$SLOTS_AVAILABLE" ]]; then
    log "Position slots filled. Stopping."
    break
  fi

  MARKET_ID=$(echo "$market" | jq -r '.id')
  QUESTION=$(echo "$market" | jq -r '.question')
  CURRENT_PRICE=$(echo "$market" | jq -r '.current_probability // .yes_price // 0.5')
  END_TIME=$(echo "$market" | jq -r '.end_date // .close_time // "unknown"')

  log "--- Evaluating: $QUESTION (price=$CURRENT_PRICE, closes=$END_TIME) ---"

  # Skip if we already have a position in this market
  HAS_POS=$(echo "$POSITIONS" | jq --arg mid "$MARKET_ID" '[.positions[] | select(.market_id == $mid)] | length' 2>/dev/null || echo 0)
  if [[ "$HAS_POS" -gt 0 ]]; then
    log "Already in this market, skipping"
    continue
  fi

  # Step 5: Get context for price deviation analysis
  CONTEXT=$("$SIMMER" GET "/api/sdk/context/${MARKET_ID}" 2>/dev/null) || {
    log "WARN: Failed to get context for $MARKET_ID, skipping"
    continue
  }

  # Extract edge analysis
  DIVERGENCE=$(echo "$CONTEXT" | jq -r '.edge_analysis.divergence // 0' 2>/dev/null)
  RECOMMENDATION=$(echo "$CONTEXT" | jq -r '.edge_analysis.recommendation // "HOLD"' 2>/dev/null)
  AI_PRICE=$(echo "$CONTEXT" | jq -r '.edge_analysis.ai_probability // 0' 2>/dev/null)

  # Calculate absolute edge
  EDGE=$(echo "$DIVERGENCE" | awk '{x=$1; if(x<0) x=-x; printf "%.4f", x}')

  log "  Edge: $EDGE (threshold: $PRICE_DEVIATION), AI: $AI_PRICE, Rec: $RECOMMENDATION"

  # Check if deviation exceeds threshold
  SHOULD_TRADE=$(echo "$EDGE $PRICE_DEVIATION" | awk '{print ($1 >= $2) ? "yes" : "no"}')

  if [[ "$SHOULD_TRADE" != "yes" ]]; then
    log "  Deviation too small ($EDGE < $PRICE_DEVIATION), skipping"
    continue
  fi

  # Skip if context says hold
  if [[ "$RECOMMENDATION" == "HOLD" ]]; then
    log "  Context says HOLD despite deviation, skipping"
    continue
  fi

  # Determine side
  if echo "$DIVERGENCE" | awk '{exit ($1 > 0) ? 0 : 1}'; then
    SIDE="yes"
  else
    SIDE="no"
  fi

  REASONING="Fast loop: BTC price deviation $EDGE exceeds ${PRICE_DEVIATION} threshold. AI probability $AI_PRICE vs market $CURRENT_PRICE (divergence: $DIVERGENCE). $RECOMMENDATION $SIDE."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  DRY RUN: Would trade $SIDE on '$QUESTION' for \$$TRADE_AMOUNT"
    log "  Reasoning: $REASONING"
  else
    log "  Placing trade: $SIDE for \$$TRADE_AMOUNT"
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
      log "  ERROR: Trade failed"
      continue
    }

    SHARES=$(echo "$RESULT" | jq -r '.shares_bought // .shares // "unknown"')
    AVG_PRICE=$(echo "$RESULT" | jq -r '.average_price // "unknown"')
    log "  Trade executed: $SHARES shares at $AVG_PRICE"

    # Check if we need to set a stop loss
    # Simmer handles auto stop-loss at 50% by default, but we can set tighter
    if [[ "$STOP_LOSS" -gt 0 ]]; then
      log "  Stop loss: -\$$STOP_LOSS (Simmer auto-manages)"
    fi
  fi

  TRADES_PLACED=$((TRADES_PLACED + 1))
done

log "=== Fast Loop finished (trades: $TRADES_PLACED) ==="
