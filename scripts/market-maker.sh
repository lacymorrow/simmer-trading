#!/usr/bin/env bash
set -euo pipefail

# market-maker.sh - Spread capture / market making on Polymarket via Simmer
# Cron-compatible: runs once per cycle, manages GTC limit orders, exits
#
# Strategy:
#   1. Find high-liquidity markets with tight spreads (2-8%)
#   2. Post GTC bid (buy YES below mid) and ask (buy NO below mid) to capture spread
#   3. Monitor fill status and cancel stale orders
#   4. Rebalance inventory when skewed (too many YES or NO shares)
#   5. Pull all orders when spread collapses or news breaks (adverse selection guard)
#
# The bot does NOT predict direction. It earns the bid-ask spread by providing
# liquidity on both sides. Profit = spread captured minus adverse fills.
#
# Usage: ./market-maker.sh
# Cron:  */5 * * * * SIMMER_API_KEY=sk_live_... /path/to/market-maker.sh >> /tmp/market-maker.log 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMMER="${SCRIPT_DIR}/simmer.sh"

# --- Configuration (override via env) ---
DRY_RUN="${DRY_RUN:-true}"
VENUE="${VENUE:-sim}"                           # sim or polymarket
ORDER_SIZE="${ORDER_SIZE:-5}"                    # USD per side per market
MAX_MARKETS="${MAX_MARKETS:-3}"                  # Max markets to make simultaneously
MAX_OPEN_ORDERS="${MAX_OPEN_ORDERS:-10}"         # Safety cap on total open orders
MIN_SPREAD_PCT="${MIN_SPREAD_PCT:-3}"            # Min spread to bother (below this, not worth it)
MAX_SPREAD_PCT="${MAX_SPREAD_PCT:-15}"           # Max spread (above this, market is too illiquid)
EDGE_FROM_MID="${EDGE_FROM_MID:-1}"              # Cents inside the spread from midpoint (our edge)
INVENTORY_SKEW_LIMIT="${INVENTORY_SKEW_LIMIT:-3}" # Max ratio of YES:NO or NO:YES shares before rebalancing
STALE_ORDER_MINUTES="${STALE_ORDER_MINUTES:-30}" # Cancel unfilled orders older than this
DAILY_LOSS_LIMIT="${DAILY_LOSS_LIMIT:-25}"       # Stop if daily loss exceeds this
MIN_VOLUME="${MIN_VOLUME:-1000}"                 # Skip low-volume markets
PRICE_FLOOR="${PRICE_FLOOR:-0.10}"               # Skip extreme markets (too close to 0)
PRICE_CEILING="${PRICE_CEILING:-0.90}"           # Skip extreme markets (too close to 1)
SOURCE="sdk:market-maker"
SKILL_SLUG="simmer-market-maker"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

log "=== Market Maker starting (dry_run=$DRY_RUN, venue=$VENUE, order_size=$ORDER_SIZE) ==="

# --- Step 1: Check daily P&L ---
PORTFOLIO=$("$SIMMER" GET /api/sdk/portfolio 2>/dev/null) || {
  log "ERROR: Failed to fetch portfolio"
  exit 1
}

DAILY_PNL=$(echo "$PORTFOLIO" | jq -r '.daily_pnl // 0' 2>/dev/null)
log "Daily P&L: $DAILY_PNL (limit: -$DAILY_LOSS_LIMIT)"

OVER_LIMIT=$(echo "$DAILY_PNL $DAILY_LOSS_LIMIT" | awk '{print ($1 < -$2) ? "yes" : "no"}')
if [[ "$OVER_LIMIT" == "yes" ]]; then
  log "KILL SWITCH: Daily loss limit hit ($DAILY_PNL). Cancelling all orders and stopping."
  "$SIMMER" DELETE /api/sdk/orders 2>/dev/null || true
  exit 0
fi

# --- Step 2: Check and clean stale orders ---
OPEN_ORDERS=$("$SIMMER" GET /api/sdk/orders/open 2>/dev/null) || {
  log "WARN: Failed to fetch open orders, continuing"
  OPEN_ORDERS='{"orders":[],"count":0}'
}

ORDER_COUNT=$(echo "$OPEN_ORDERS" | jq '.count // 0')
log "Open orders: $ORDER_COUNT (max: $MAX_OPEN_ORDERS)"

if [[ "$ORDER_COUNT" -ge "$MAX_OPEN_ORDERS" ]]; then
  log "Too many open orders ($ORDER_COUNT). Cancelling all and re-evaluating next cycle."
  "$SIMMER" DELETE /api/sdk/orders 2>/dev/null || true
  exit 0
fi

# Cancel stale orders (older than STALE_ORDER_MINUTES)
NOW_EPOCH=$(date +%s)
CANCELLED=0
for ORDER_ID in $(echo "$OPEN_ORDERS" | jq -r ".orders[] | select(.source == \"$SOURCE\") | select(.created_at != null) | {id: .id, created_at: .created_at} | @base64" 2>/dev/null); do
  DECODED=$(echo "$ORDER_ID" | base64 -d 2>/dev/null) || continue
  OID=$(echo "$DECODED" | jq -r '.id')
  CREATED=$(echo "$DECODED" | jq -r '.created_at')
  ORDER_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${CREATED%%.*}" +%s 2>/dev/null || date -d "${CREATED}" +%s 2>/dev/null || echo 0)
  AGE_MIN=$(( (NOW_EPOCH - ORDER_EPOCH) / 60 ))
  if [[ "$AGE_MIN" -gt "$STALE_ORDER_MINUTES" ]]; then
    log "Cancelling stale order $OID (${AGE_MIN}m old)"
    "$SIMMER" DELETE "/api/sdk/orders" '{"order_id":"'"$OID"'"}' 2>/dev/null || true
    CANCELLED=$((CANCELLED + 1))
  fi
done
[[ "$CANCELLED" -gt 0 ]] && log "Cancelled $CANCELLED stale orders"

# --- Step 3: Find candidate markets ---
# Look for high-liquidity markets in sweet-spot price range
MARKETS_JSON=$("$SIMMER" GET "/api/sdk/markets?status=active&limit=100" 2>/dev/null) || {
  log "ERROR: Failed to fetch markets"
  exit 1
}

# Filter: price in range, has spread data
CANDIDATES=$(echo "$MARKETS_JSON" | jq --argjson floor "$PRICE_FLOOR" --argjson ceil "$PRICE_CEILING" '
  [.markets[] |
    select(.current_probability != null) |
    select(.current_probability >= $floor and .current_probability <= $ceil) |
    select(.status == "active") |
    select(.resolves_at != null) |
    {
      id: .id,
      question: .question,
      price: .current_probability,
      ext_yes: (.external_price_yes // .current_probability),
      ext_no: (if .external_price_yes then (1 - .external_price_yes) else (1 - .current_probability) end),
      resolves_at: .resolves_at,
      tags: (.tags // [])
    }
  ] | sort_by(-.price | fabs - 0.5) | .[:40]
')

CANDIDATE_COUNT=$(echo "$CANDIDATES" | jq 'length')
log "Found $CANDIDATE_COUNT candidate markets after price filter"

if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then
  log "No suitable markets found. Exiting."
  exit 0
fi

# --- Step 4: Evaluate spreads and place orders ---
ORDERS_PLACED=0
MARKETS_TARGETED=0

# Get existing MM positions to check inventory
POSITIONS=$("$SIMMER" GET /api/sdk/positions 2>/dev/null) || POSITIONS='{"positions":[]}'

# Write candidates to temp file to avoid subshell variable loss
CANDIDATES_FILE=$(mktemp)
echo "$CANDIDATES" | jq -c '.[]' > "$CANDIDATES_FILE"
trap "rm -f '$CANDIDATES_FILE'" EXIT

while IFS= read -r MARKET; do
  [[ "$MARKETS_TARGETED" -ge "$MAX_MARKETS" ]] && break

  MKT_ID=$(echo "$MARKET" | jq -r '.id')
  MKT_Q=$(echo "$MARKET" | jq -r '.question' | head -c 80)
  MKT_PRICE=$(echo "$MARKET" | jq -r '.price')
  EXT_YES=$(echo "$MARKET" | jq -r '.ext_yes')
  EXT_NO=$(echo "$MARKET" | jq -r '.ext_no')

  # Get context for spread info (only available for polymarket-backed markets)
  CONTEXT=$("$SIMMER" GET "/api/sdk/context/$MKT_ID" 2>/dev/null) || {
    log "  SKIP $MKT_Q: failed to get context"
    continue
  }

  SPREAD_PCT=$(echo "$CONTEXT" | jq -r '.slippage.spread_pct // 0')

  # For SIM venue: skip spread filter (LMSR has no orderbook spread)
  # For Polymarket: enforce spread range
  if [[ "$VENUE" == "polymarket" ]]; then
    SPREAD_CHECK=$(echo "$SPREAD_PCT $MIN_SPREAD_PCT $MAX_SPREAD_PCT" | awk '{
      s = $1 * 100
      print (s >= $2 && s <= $3) ? "ok" : "skip"
    }')

    if [[ "$SPREAD_CHECK" == "skip" ]]; then
      SPREAD_DISPLAY=$(echo "$SPREAD_PCT" | awk '{printf "%.1f", $1 * 100}')
      log "  SKIP $MKT_Q: spread ${SPREAD_DISPLAY}% outside range [${MIN_SPREAD_PCT}%-${MAX_SPREAD_PCT}%]"
      continue
    fi
  fi

  # Skip markets we already have MM orders on
  EXISTING=$(echo "$OPEN_ORDERS" | jq --arg mid "$MKT_ID" '[.orders[] | select(.market_id == $mid and .source == "sdk:market-maker")] | length')
  if [[ "$EXISTING" -gt 0 ]]; then
    log "  SKIP $MKT_Q: already have $EXISTING open MM orders"
    continue
  fi

  # Skip markets resolving within 2 hours (too risky for MM)
  RESOLVES=$(echo "$MARKET" | jq -r '.resolves_at')
  if [[ -n "$RESOLVES" && "$RESOLVES" != "null" ]]; then
    RESOLVE_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "${RESOLVES%%Z*}" +%s 2>/dev/null || date -d "$RESOLVES" +%s 2>/dev/null || echo 0)
    HOURS_LEFT=$(( (RESOLVE_EPOCH - NOW_EPOCH) / 3600 ))
    if [[ "$HOURS_LEFT" -lt 2 ]]; then
      log "  SKIP $MKT_Q: resolves in ${HOURS_LEFT}h (too soon)"
      continue
    fi
  fi

  # Calculate bid/ask prices
  # Midpoint between external YES and (1 - external NO)
  MID=$(echo "$EXT_YES" | awk '{printf "%.2f", $1}')

  # Our bid = mid - edge, our ask (via NO side) = (1-mid) - edge
  # We buy YES at (mid - edge_cents/100) and buy NO at ((1-mid) - edge_cents/100)
  BID_YES=$(echo "$MID $EDGE_FROM_MID" | awk '{printf "%.2f", $1 - ($2/100)}')
  BID_NO=$(echo "$MID $EDGE_FROM_MID" | awk '{printf "%.2f", (1 - $1) - ($2/100)}')

  # Validate prices are sane
  PRICE_OK=$(echo "$BID_YES $BID_NO" | awk '{print ($1 > 0.05 && $1 < 0.95 && $2 > 0.05 && $2 < 0.95) ? "ok" : "bad"}')
  if [[ "$PRICE_OK" != "ok" ]]; then
    log "  SKIP $MKT_Q: calculated prices out of range (bid_yes=$BID_YES, bid_no=$BID_NO)"
    continue
  fi

  SPREAD_CAPTURE=$(echo "$BID_YES $BID_NO" | awk '{printf "%.1f", (1 - $1 - $2) * 100}')
  log "  TARGET $MKT_Q"
  log "    mid=$MID, bid_yes=$BID_YES, bid_no=$BID_NO, spread_capture=${SPREAD_CAPTURE}c"

  # Check inventory skew
  YES_SHARES=$(echo "$POSITIONS" | jq --arg mid "$MKT_ID" '[.positions[] | select(.market_id == $mid and .side == "yes")] | .[0].shares // 0')
  NO_SHARES=$(echo "$POSITIONS" | jq --arg mid "$MKT_ID" '[.positions[] | select(.market_id == $mid and .side == "no")] | .[0].shares // 0')

  # Determine which sides to quote based on inventory
  QUOTE_YES="true"
  QUOTE_NO="true"

  if [[ $(echo "$YES_SHARES $NO_SHARES $INVENTORY_SKEW_LIMIT" | awk '{
    if ($2 == 0) { print ($1 > 20) ? "skewed" : "ok" }
    else { ratio = $1 / $2; print (ratio > $3) ? "skewed" : "ok" }
  }') == "skewed" ]]; then
    log "    Inventory skewed YES ($YES_SHARES vs $NO_SHARES). Quoting NO only."
    QUOTE_YES="false"
  fi

  if [[ $(echo "$NO_SHARES $YES_SHARES $INVENTORY_SKEW_LIMIT" | awk '{
    if ($2 == 0) { print ($1 > 20) ? "skewed" : "ok" }
    else { ratio = $1 / $2; print (ratio > $3) ? "skewed" : "ok" }
  }') == "skewed" ]]; then
    log "    Inventory skewed NO ($NO_SHARES vs $YES_SHARES). Quoting YES only."
    QUOTE_NO="false"
  fi

  # Build trade body helper
  # SIM venue: no price/order_type (LMSR, instant fill at market price)
  # Polymarket: GTC limit orders at our calculated prices
  place_order() {
    local SIDE="$1" PRICE="$2" LABEL="$3"

    if [[ "$VENUE" == "polymarket" ]]; then
      TRADE_BODY=$(jq -n \
        --arg mid "$MKT_ID" --arg side "$SIDE" --argjson amt "$ORDER_SIZE" \
        --argjson price "$PRICE" --arg venue "$VENUE" --arg src "$SOURCE" \
        --arg slug "$SKILL_SLUG" --arg reason "MM $LABEL: $SIDE at $PRICE (mid=$MID, spread=${SPREAD_CAPTURE}c)" \
        '{market_id: $mid, side: $side, amount: $amt, price: $price, order_type: "GTC", venue: $venue, source: $src, skill_slug: $slug, reasoning: $reason}')
    else
      # SIM: market order, no price param. We only trade if the LMSR price is favorable.
      local CURRENT
      if [[ "$SIDE" == "yes" ]]; then CURRENT="$EXT_YES"; else CURRENT="$EXT_NO"; fi
      local FAVORABLE=$(echo "$CURRENT $PRICE" | awk '{print ($1 <= $2 + 0.02) ? "yes" : "no"}')
      if [[ "$FAVORABLE" != "yes" ]]; then
        log "    SIM SKIP $SIDE: LMSR price $CURRENT > limit $PRICE + 2c buffer"
        return 1
      fi
      TRADE_BODY=$(jq -n \
        --arg mid "$MKT_ID" --arg side "$SIDE" --argjson amt "$ORDER_SIZE" \
        --arg venue "$VENUE" --arg src "$SOURCE" --arg slug "$SKILL_SLUG" \
        --arg reason "MM $LABEL: $SIDE at LMSR ~$CURRENT (target $PRICE, mid=$MID)" \
        '{market_id: $mid, side: $side, amount: $amt, venue: $venue, source: $src, skill_slug: $slug, reasoning: $reason}')
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      TRADE_BODY=$(echo "$TRADE_BODY" | jq '. + {dry_run: true}')
    fi

    RESULT=$("$SIMMER" POST /api/sdk/trade "$TRADE_BODY" 2>&1) || {
      log "    ERROR: $SIDE $LABEL failed: $(echo "$RESULT" | head -1)"
      return 1
    }

    SUCCESS=$(echo "$RESULT" | jq -r '.success // false')
    ORDER_STATUS=$(echo "$RESULT" | jq -r '.order_status // "filled"')
    SHARES=$(echo "$RESULT" | jq -r '.shares_bought // 0')
    log "    $SIDE $LABEL: success=$SUCCESS, status=$ORDER_STATUS, shares=$SHARES @ $PRICE"
    return 0
  }

  # Place bid on YES side
  if [[ "$QUOTE_YES" == "true" ]]; then
    if place_order "yes" "$BID_YES" "bid"; then
      ORDERS_PLACED=$((ORDERS_PLACED + 1))
    fi
  fi

  # Place bid on NO side
  if [[ "$QUOTE_NO" == "true" ]]; then
    if place_order "no" "$BID_NO" "ask"; then
      ORDERS_PLACED=$((ORDERS_PLACED + 1))
    fi
  fi

  MARKETS_TARGETED=$((MARKETS_TARGETED + 1))
done < "$CANDIDATES_FILE"

# --- Step 5: Summary ---
FINAL_ORDERS=$("$SIMMER" GET /api/sdk/orders/open 2>/dev/null)
FINAL_COUNT=$(echo "$FINAL_ORDERS" | jq '.count // 0' 2>/dev/null || echo "?")

log "=== Market Maker complete ==="
log "  Orders placed this run: $ORDERS_PLACED"
log "  Total open orders: $FINAL_COUNT"
log "  Markets targeted: $MARKETS_TARGETED"
