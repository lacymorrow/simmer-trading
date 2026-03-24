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

# NOAA grid points for US cities
# Format: "LAT,LON" - NOAA will give us the grid office/point
declare -A CITY_COORDS=(
  ["new york"]="40.7128,-74.0060"
  ["nyc"]="40.7128,-74.0060"
  ["new york city"]="40.7128,-74.0060"
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
  ["austin"]="30.2672,-97.7431"
  ["nashville"]="36.1627,-86.7816"
  ["minneapolis"]="44.9778,-93.2650"
  ["detroit"]="42.3314,-83.0458"
  ["portland"]="45.5152,-122.6784"
  ["las vegas"]="36.1699,-115.1398"
  ["orlando"]="28.5383,-81.3792"
  ["san diego"]="32.7157,-117.1611"
  ["san antonio"]="29.4241,-98.4936"
  ["philadelphia"]="39.9526,-75.1652"
  ["charlotte"]="35.2271,-80.8431"
  ["indianapolis"]="39.7684,-86.1581"
  ["columbus"]="39.9612,-82.9988"
  ["jacksonville"]="30.3322,-81.6557"
  ["milwaukee"]="43.0389,-87.9065"
  ["memphis"]="35.1495,-90.0490"
  ["oklahoma city"]="35.4676,-97.5164"
  ["louisville"]="38.2527,-85.7585"
  ["baltimore"]="39.2904,-76.6122"
  ["salt lake city"]="40.7608,-111.8910"
  ["kansas city"]="39.0997,-94.5786"
  ["raleigh"]="35.7796,-78.6382"
  ["st. louis"]="38.6270,-90.1994"
  ["st louis"]="38.6270,-90.1994"
  ["tampa"]="27.9506,-82.4572"
  ["pittsburgh"]="40.4406,-79.9959"
  ["cincinnati"]="39.1031,-84.5120"
  ["new orleans"]="29.9511,-90.0715"
  ["sacramento"]="38.5816,-121.4944"
)

# International cities for Open-Meteo (LAT,LON)
declare -A INTL_COORDS=(
  ["hong kong"]="22.3193,114.1694"
  ["london"]="51.5074,-0.1278"
  ["tokyo"]="35.6762,139.6503"
  ["tel aviv"]="32.0853,34.7818"
  ["shanghai"]="31.2304,121.4737"
  ["buenos aires"]="-34.6037,-58.3816"
  ["beijing"]="39.9042,116.4074"
  ["seoul"]="37.5665,126.9780"
  ["mumbai"]="19.0760,72.8777"
  ["sydney"]="-33.8688,151.2093"
  ["dubai"]="25.2048,55.2708"
  ["paris"]="48.8566,2.3522"
  ["berlin"]="52.5200,13.4050"
  ["madrid"]="40.4168,-3.7038"
  ["rome"]="41.9028,12.4964"
  ["milan"]="45.4642,9.1900"
  ["bangkok"]="13.7563,100.5018"
  ["singapore"]="1.3521,103.8198"
  ["toronto"]="43.6532,-79.3832"
  ["mexico city"]="19.4326,-99.1332"
  ["cairo"]="30.0444,31.2357"
  ["jakarta"]="-6.2088,106.8456"
  ["istanbul"]="41.0082,28.9784"
  ["moscow"]="55.7558,37.6173"
  ["rio de janeiro"]="-22.9068,-43.1729"
  ["sao paulo"]="-23.5505,-46.6333"
  ["wuhan"]="30.5928,114.3055"
  ["osaka"]="34.6937,135.5023"
  ["taipei"]="25.0330,121.5654"
  ["kuala lumpur"]="3.1390,101.6869"
  ["johannesburg"]="-26.2041,28.0473"
  ["lima"]="-12.0464,-77.0428"
  ["bogota"]="4.7110,-74.0721"
  ["santiago"]="-33.4489,-70.6693"
  ["nairobi"]="-1.2921,36.8219"
  ["amsterdam"]="52.3676,4.9041"
  ["zurich"]="47.3769,8.5417"
  ["vienna"]="48.2082,16.3738"
  ["stockholm"]="59.3293,18.0686"
  ["athens"]="37.9838,23.7275"
  ["lisbon"]="38.7223,-9.1393"
  ["warsaw"]="52.2297,21.0122"
  ["prague"]="50.0755,14.4378"
  ["dublin"]="53.3498,-6.2603"
  ["lagos"]="6.5244,3.3792"
  ["cape town"]="-33.9249,18.4241"
  ["melbourne"]="-37.8136,144.9631"
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

# Fetch Open-Meteo forecast for international cities
# Returns JSON array matching NOAA format: [{name, temp (in F), unit}]
get_openmeteo_forecast() {
  local city="$1"
  local city_lower=$(echo "$city" | tr '[:upper:]' '[:lower:]')
  local coords="${INTL_COORDS[$city_lower]:-}"

  if [[ -z "$coords" ]]; then
    echo ""
    return
  fi

  local lat=$(echo "$coords" | cut -d, -f1)
  local lon=$(echo "$coords" | cut -d, -f2)

  # Open-Meteo free API: 7-day forecast with daily max temp
  local url="https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&daily=temperature_2m_max&temperature_unit=fahrenheit&timezone=auto&forecast_days=7"
  local resp
  resp=$(curl -sf --max-time 10 "$url" 2>/dev/null) || {
    echo ""
    return
  }

  # Convert to same format as NOAA output
  echo "$resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
dates = data.get('daily', {}).get('time', [])
temps = data.get('daily', {}).get('temperature_2m_max', [])
result = []
for d, t in zip(dates, temps):
    if t is not None:
        result.append({'name': d, 'temp': round(t), 'unit': 'F'})
print(json.dumps(result))
" 2>/dev/null
}

# Unified forecast: try NOAA for US cities, Open-Meteo for international
get_forecast() {
  local city="$1"
  local city_lower=$(echo "$city" | tr '[:upper:]' '[:lower:]')

  # Try NOAA first (US cities)
  if [[ -n "${CITY_COORDS[$city_lower]:-}" ]]; then
    get_noaa_forecast "$city"
    return
  fi

  # Fall back to Open-Meteo (international)
  if [[ -n "${INTL_COORDS[$city_lower]:-}" ]]; then
    get_openmeteo_forecast "$city"
    return
  fi

  # Unknown city
  echo ""
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

  # Step 4: Get forecast (NOAA for US, Open-Meteo for international)
  CITY_LOWER=$(echo "$CITY" | tr '[:upper:]' '[:lower:]')
  if [[ -z "${CITY_COORDS[$CITY_LOWER]:-}" && -z "${INTL_COORDS[$CITY_LOWER]:-}" ]]; then
    log "  No forecast data for $CITY (not configured), skipping"
    continue
  fi

  FORECAST=$(get_forecast "$CITY")
  if [[ -z "$FORECAST" || "$FORECAST" == "null" || "$FORECAST" == "[]" ]]; then
    log "  Failed to get forecast for $CITY, skipping"
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
