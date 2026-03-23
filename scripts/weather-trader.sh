#!/usr/bin/env bash
set -euo pipefail

# weather-trader.sh - Trade weather prediction markets with NOAA forecast verification
# Cron-compatible: runs once, logs reasoning, exits
#
# Strategy:
#   1. Fetch weather markets from Simmer
#   2. Parse the city and temperature threshold from the question
#   3. Fetch NOAA forecast for that city
#   4. Compare forecast vs market question to estimate true probability
#   5. Only trade when our forecast probability diverges from market price
#   6. Set risk monitors (stop-loss + take-profit) on every trade
#
# Usage: ./weather-trader.sh
# Cron:  */2 * * * * SIMMER_API_KEY=sk_live_... /path/to/weather-trader.sh >> /tmp/weather-trader.log 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMMER="${SCRIPT_DIR}/simmer.sh"

# --- Configuration ---
DRY_RUN="${DRY_RUN:-true}"
EDGE_PCT_THRESHOLD="${EDGE_PCT_THRESHOLD:-20}"  # Need 20%+ relative edge to trade
MIN_PRICE="${MIN_PRICE:-0.02}"                  # Skip sub-2-cent markets
MAX_PRICE="${MAX_PRICE:-0.85}"                  # Skip markets already priced high (no upside)
MAX_SPREAD_PCT="${MAX_SPREAD_PCT:-40}"          # Skip illiquid markets
TRADE_AMOUNT="${TRADE_AMOUNT:-2}"               # USD per trade
VENUE="${VENUE:-sim}"                           # sim or polymarket
MAX_TRADES="${MAX_TRADES:-3}"                   # Max trades per run
STOP_LOSS_PCT="${STOP_LOSS_PCT:-0.30}"          # Auto-sell at -30%
TAKE_PROFIT_PCT="${TAKE_PROFIT_PCT:-1.00}"      # Auto-sell at +100%
MAX_DAILY_LOSS="${MAX_DAILY_LOSS:-20}"          # Stop trading if daily loss exceeds this
SOURCE="sdk:weather-trader"
SKILL_SLUG="simmer-weather-trader"

# NOAA grid points for supported cities
# Format: "LAT,LON" - NOAA will give us the grid office/point
declare -A CITY_COORDS=(
  ["new york"]="40.7128,-74.0060"
  ["nyc"]="40.7128,-74.0060"
  ["new york city"]="40.7128,-74.0060"
  ["new york"]="40.7128,-74.0060"
  ["chicago"]="41.8781,-87.6298"
  ["seattle"]="47.6062,-122.3321"
  ["atlanta"]="33.7490,-84.3880"
  ["dallas"]="32.7767,-96.7970"
  ["miami"]="25.7617,-80.1918"
  ["los angeles"]="34.0522,-118.2437"
  ["denver"]="39.7392,-104.9903"
  ["houston"]="29.7604,-95.3698"
  ["phoenix"]="33.4484,-112.0740"
  ["san francisco"]="37.7749,-122.4194"
  ["boston"]="42.3601,-71.0589"
  ["washington"]="38.9072,-77.0369"
  ["washington dc"]="38.9072,-77.0369"
  ["hong kong"]=""
  ["london"]=""
  ["tokyo"]=""
  ["tel aviv"]=""
)

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

# Extract city from question like "Will the highest temperature in Seattle be..."
extract_city() {
  local question="$1"
  # Match "in CITY be" - city is the word(s) between "in" and "be"
  # Handle multi-word cities like "New York", "Los Angeles", "Hong Kong"
  echo "$question" | sed -E 's/.*temperature in ([A-Za-z ]+) be .*/\1/' | tr '[:upper:]' '[:lower:]' | sed 's/ *$//'
}

# Extract temperature threshold and comparison from question
# Returns: "TEMP OPERATOR" e.g. "62 ge" or "43 le" or "90 91 between"
# Handles both °F and °C (converts C to F for comparison)
extract_temp_condition() {
  local question="$1"

  # Fahrenheit
  if echo "$question" | grep -q '°F or higher'; then
    echo "$question" | sed -n 's/.*be \([0-9]*\)°F or higher.*/\1 ge/p'
  elif echo "$question" | grep -q '°F or below'; then
    echo "$question" | sed -n 's/.*be \([0-9]*\)°F or below.*/\1 le/p'
  elif echo "$question" | grep -q 'between.*°F'; then
    echo "$question" | sed -n 's/.*between \([0-9]*\)-\([0-9]*\)°F.*/\1 \2 between/p'
  # Celsius - convert to F
  elif echo "$question" | grep -q '°C or higher'; then
    local c=$(echo "$question" | sed -n 's/.*be \([0-9]*\)°C or higher.*/\1/p')
    local f=$(echo "$c" | awk '{printf "%d", $1 * 9/5 + 32}')
    echo "$f ge"
  elif echo "$question" | grep -q '°C or below'; then
    local c=$(echo "$question" | sed -n 's/.*be \([0-9]*\)°C or below.*/\1/p')
    local f=$(echo "$c" | awk '{printf "%d", $1 * 9/5 + 32}')
    echo "$f le"
  elif echo "$question" | grep -q '°C on\|°C '; then
    # Exact temp in C like "be 20°C on March 27"
    local c=$(echo "$question" | sed -n 's/.*be \([0-9]*\)°C.*/\1/p')
    if [[ -n "$c" ]]; then
      local f_low=$(echo "$c" | awk '{printf "%d", $1 * 9/5 + 32 - 1}')
      local f_high=$(echo "$c" | awk '{printf "%d", $1 * 9/5 + 32 + 1}')
      echo "$f_low $f_high between"
    else
      echo ""
    fi
  else
    echo ""
  fi
}

# Fetch NOAA forecast high temperature for a city on a given date
# Returns forecast high temp in F, or empty on failure
get_noaa_forecast() {
  local city="$1"
  local city_lower=$(echo "$city" | tr '[:upper:]' '[:lower:]')
  local coords="${CITY_COORDS[$city_lower]:-}"

  if [[ -z "$coords" ]]; then
    echo ""
    return
  fi

  local lat=$(echo "$coords" | cut -d, -f1)
  local lon=$(echo "$coords" | cut -d, -f2)

  # Get NOAA grid point
  local grid_url="https://api.weather.gov/points/${lat},${lon}"
  local grid_resp
  grid_resp=$(curl -sf -H "User-Agent: simmer-trading/1.0" "$grid_url" 2>/dev/null) || {
    echo ""
    return
  }

  local forecast_url
  forecast_url=$(echo "$grid_resp" | jq -r '.properties.forecast // empty' 2>/dev/null) || {
    echo ""
    return
  }

  if [[ -z "$forecast_url" ]]; then
    echo ""
    return
  fi

  # Get the forecast
  local forecast
  forecast=$(curl -sf -H "User-Agent: simmer-trading/1.0" "$forecast_url" 2>/dev/null) || {
    echo ""
    return
  }

  # Return all daytime forecast high temps as JSON array
  echo "$forecast" | jq '[.properties.periods[] | select(.isDaytime == true) | {name: .name, temp: .temperature, unit: .temperatureUnit}]' 2>/dev/null
}

# Estimate probability based on NOAA forecast vs market question
# Returns probability 0-1 or empty if can't determine
estimate_probability() {
  local forecast_temps="$1"  # JSON array from get_noaa_forecast
  local condition="$2"       # e.g. "62 ge" or "43 le" or "90 91 between"
  local market_date="$3"     # resolve date for matching forecast day

  if [[ -z "$forecast_temps" || "$forecast_temps" == "null" || -z "$condition" ]]; then
    echo ""
    return
  fi

  # Get the forecast high for the target day (use first available as approximation)
  # NOAA gives 7 days, periods[0] is today/tonight
  local forecast_high
  forecast_high=$(echo "$forecast_temps" | jq -r '.[0].temp // empty' 2>/dev/null)

  if [[ -z "$forecast_high" ]]; then
    echo ""
    return
  fi

  local parts=($condition)
  local result=""

  case "${parts[-1]}" in
    ge)
      local threshold="${parts[0]}"
      # How far is forecast from threshold?
      local diff=$((forecast_high - threshold))
      if [[ $diff -ge 10 ]]; then
        result="0.95"
      elif [[ $diff -ge 5 ]]; then
        result="0.85"
      elif [[ $diff -ge 2 ]]; then
        result="0.70"
      elif [[ $diff -ge 0 ]]; then
        result="0.55"
      elif [[ $diff -ge -2 ]]; then
        result="0.35"
      elif [[ $diff -ge -5 ]]; then
        result="0.15"
      else
        result="0.05"
      fi
      ;;
    le)
      local threshold="${parts[0]}"
      local diff=$((threshold - forecast_high))
      if [[ $diff -ge 10 ]]; then
        result="0.95"
      elif [[ $diff -ge 5 ]]; then
        result="0.85"
      elif [[ $diff -ge 2 ]]; then
        result="0.70"
      elif [[ $diff -ge 0 ]]; then
        result="0.55"
      elif [[ $diff -ge -2 ]]; then
        result="0.35"
      elif [[ $diff -ge -5 ]]; then
        result="0.15"
      else
        result="0.05"
      fi
      ;;
    between)
      local low="${parts[0]}"
      local high="${parts[1]}"
      local mid=$(( (low + high) / 2 ))
      local diff_from_mid=$(( forecast_high - mid ))
      if [[ $diff_from_mid -lt 0 ]]; then
        diff_from_mid=$(( -diff_from_mid ))
      fi
      # 2-degree window is tight
      if [[ $diff_from_mid -le 1 ]]; then
        result="0.25"
      elif [[ $diff_from_mid -le 3 ]]; then
        result="0.12"
      elif [[ $diff_from_mid -le 5 ]]; then
        result="0.05"
      else
        result="0.02"
      fi
      ;;
    *)
      result=""
      ;;
  esac

  echo "$result"
}

log "=== Weather Trader starting (dry_run=$DRY_RUN, edge_pct=$EDGE_PCT_THRESHOLD%, venue=$VENUE) ==="

# Step 0: Check daily P&L
PORTFOLIO=$("$SIMMER" GET /api/sdk/portfolio 2>/dev/null) || true
DAILY_PNL=$(echo "$PORTFOLIO" | jq -r '.daily_pnl // 0' 2>/dev/null || echo "0")
OVER_LIMIT=$(echo "$DAILY_PNL $MAX_DAILY_LOSS" | awk '{print ($1 < -$2) ? "yes" : "no"}')
if [[ "$OVER_LIMIT" == "yes" ]]; then
  log "Daily loss limit hit ($DAILY_PNL > -$MAX_DAILY_LOSS). Stopping."
  exit 0
fi
log "Daily P&L: $DAILY_PNL (limit: -$MAX_DAILY_LOSS)"

# Step 1: Fetch weather markets
log "Fetching weather markets..."
MARKETS=$("$SIMMER" GET "/api/sdk/markets?tags=weather&status=active&limit=30" 2>/dev/null) || {
  log "ERROR: Failed to fetch markets"
  exit 1
}

MARKET_COUNT=$(echo "$MARKETS" | jq '.markets | length' 2>/dev/null || echo 0)
log "Found $MARKET_COUNT weather markets"

if [[ "$MARKET_COUNT" -eq 0 ]]; then
  log "No weather markets found. Exiting."
  exit 0
fi

# Pre-fetch existing positions to avoid re-buying
EXISTING_POSITIONS=$("$SIMMER" GET /api/sdk/positions 2>/dev/null) || EXISTING_POSITIONS='{"positions":[]}'
HELD_MARKET_IDS=$(echo "$EXISTING_POSITIONS" | jq -r '[.positions[].market_id] | join(",")' 2>/dev/null || echo "")

# Step 2: Process each market
TRADES_PLACED=0
CONTEXT_CALLS=0

echo "$MARKETS" | jq -c '.markets[]' 2>/dev/null | while IFS= read -r market; do
  if [[ "$TRADES_PLACED" -ge "$MAX_TRADES" ]]; then
    log "Max trades reached ($MAX_TRADES). Stopping."
    break
  fi

  MARKET_ID=$(echo "$market" | jq -r '.id')
  QUESTION=$(echo "$market" | jq -r '.question')
  CURRENT_PRICE=$(echo "$market" | jq -r '.current_probability // .yes_price // 0')
  RESOLVE_DATE=$(echo "$market" | jq -r '.resolves_at // "unknown"')

  # Pre-filter on price range (before spending API calls)
  PRICE_LOW=$(echo "$CURRENT_PRICE $MIN_PRICE" | awk '{print ($1 < $2) ? "yes" : "no"}')
  PRICE_HIGH=$(echo "$CURRENT_PRICE $MAX_PRICE" | awk '{print ($1 > $2) ? "yes" : "no"}')
  if [[ "$PRICE_LOW" == "yes" ]]; then
    continue  # too cheap, illiquid
  fi
  if [[ "$PRICE_HIGH" == "yes" ]]; then
    continue  # too expensive, no edge
  fi

  # Skip if we already hold this market
  if echo "$HELD_MARKET_IDS" | grep -q "$MARKET_ID"; then
    continue
  fi

  log "--- Evaluating: $QUESTION (price=$CURRENT_PRICE) ---"

  # Step 3: Parse city and temperature from question
  CITY=$(extract_city "$QUESTION")
  TEMP_CONDITION=$(extract_temp_condition "$QUESTION")

  if [[ -z "$CITY" || -z "$TEMP_CONDITION" ]]; then
    log "  Can't parse city/temp from question, skipping"
    continue
  fi

  # Step 4: Get NOAA forecast
  CITY_LOWER=$(echo "$CITY" | tr '[:upper:]' '[:lower:]')
  if [[ -z "${CITY_COORDS[$CITY_LOWER]:-}" ]]; then
    log "  No NOAA data for $CITY (no coords configured), skipping"
    continue
  fi

  FORECAST=$(get_noaa_forecast "$CITY")
  if [[ -z "$FORECAST" || "$FORECAST" == "null" ]]; then
    log "  Failed to get NOAA forecast for $CITY, skipping"
    continue
  fi

  FORECAST_HIGH=$(echo "$FORECAST" | jq -r '.[0].temp // "?"' 2>/dev/null)
  log "  NOAA forecast high for $CITY: ${FORECAST_HIGH}F"

  # Step 5: Estimate probability from forecast
  OUR_PROB=$(estimate_probability "$FORECAST" "$TEMP_CONDITION" "$RESOLVE_DATE")
  if [[ -z "$OUR_PROB" ]]; then
    log "  Can't estimate probability, skipping"
    continue
  fi

  # Calculate edge: our probability vs market price
  EDGE_ABS=$(echo "$OUR_PROB $CURRENT_PRICE" | awk '{d=$1-$2; if(d<0)d=-d; print d}')
  EDGE_PCT=$(echo "$EDGE_ABS $CURRENT_PRICE" | awk '{if($2>0) printf "%.1f", ($1/$2)*100; else print "0"}')

  # Determine direction: do we think YES or NO?
  OUR_SIDE=$(echo "$OUR_PROB $CURRENT_PRICE" | awk '{print ($1 > $2) ? "yes" : "no"}')

  log "  Our prob: $OUR_PROB, market: $CURRENT_PRICE, edge: ${EDGE_PCT}%, side: $OUR_SIDE"

  # Only trade if edge is large enough
  SHOULD_TRADE=$(echo "$EDGE_PCT $EDGE_PCT_THRESHOLD" | awk '{print ($1 >= $2) ? "yes" : "no"}')
  if [[ "$SHOULD_TRADE" != "yes" ]]; then
    log "  Edge too small (${EDGE_PCT}% < ${EDGE_PCT_THRESHOLD}%), skipping"
    continue
  fi

  # Step 6: Check context for spread/position (rate limited)
  if [[ $CONTEXT_CALLS -ge 18 ]]; then
    log "  Approaching context rate limit ($CONTEXT_CALLS calls), stopping"
    break
  fi
  sleep 3
  CONTEXT_CALLS=$((CONTEXT_CALLS + 1))

  CONTEXT=$("$SIMMER" GET "/api/sdk/context/${MARKET_ID}" 2>/dev/null) || {
    log "  Failed to get context, skipping"
    continue
  }

  # Check spread
  CTX_SPREAD=$(echo "$CONTEXT" | jq -r '.slippage.spread_pct // 0' 2>/dev/null)
  SPREAD_BAD=$(echo "$CTX_SPREAD $MAX_SPREAD_PCT" | awk '{print ($1 > $2) ? "yes" : "no"}')
  if [[ "$SPREAD_BAD" == "yes" ]]; then
    log "  Spread too wide (${CTX_SPREAD}% > ${MAX_SPREAD_PCT}%), skipping"
    continue
  fi

  # Check existing position
  HAS_POSITION=$(echo "$CONTEXT" | jq -r '.position.shares // 0' 2>/dev/null)
  IS_HOLDING=$(echo "$HAS_POSITION" | awk '{print ($1 > 0) ? "yes" : "no"}')
  if [[ "$IS_HOLDING" == "yes" ]]; then
    log "  Already holding ($HAS_POSITION shares), skipping"
    continue
  fi

  REASONING="NOAA forecast: ${FORECAST_HIGH}F for $CITY. Market asks: $QUESTION. Our estimate: ${OUR_PROB} (${EDGE_PCT}% edge over market at $CURRENT_PRICE). Spread: ${CTX_SPREAD}%."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  DRY RUN: Would trade $OUR_SIDE for \$$TRADE_AMOUNT"
    log "  Reasoning: $REASONING"
  else
    log "  Placing trade: $OUR_SIDE for \$$TRADE_AMOUNT"
    TRADE_BODY=$(jq -n \
      --arg market_id "$MARKET_ID" \
      --arg side "$OUR_SIDE" \
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

    SHARES=$(echo "$RESULT" | jq -r '.shares_bought // .shares // "0"')
    # Check if we actually got shares
    GOT_SHARES=$(echo "$SHARES" | awk '{print ($1 > 0) ? "yes" : "no"}')
    if [[ "$GOT_SHARES" != "yes" ]]; then
      log "  Trade returned 0 shares (likely already holding or insufficient liquidity)"
      continue
    fi
    log "  Trade executed: $SHARES shares of $OUR_SIDE"

    # Set risk monitors
    MONITOR_BODY=$(jq -n \
      --arg side "$OUR_SIDE" \
      --argjson stop_loss_pct "$STOP_LOSS_PCT" \
      --argjson take_profit_pct "$TAKE_PROFIT_PCT" \
      '{side: $side, stop_loss_pct: $stop_loss_pct, take_profit_pct: $take_profit_pct}')

    "$SIMMER" POST "/api/sdk/positions/${MARKET_ID}/monitor" "$MONITOR_BODY" >/dev/null 2>&1 || {
      log "  WARN: Failed to set risk monitor"
    }
    log "  Risk monitor set: stop-loss ${STOP_LOSS_PCT}, take-profit ${TAKE_PROFIT_PCT}"
  fi

  TRADES_PLACED=$((TRADES_PLACED + 1))
done

log "=== Weather Trader finished (trades: $TRADES_PLACED) ==="
