#!/usr/bin/env bash
set -euo pipefail

# cron-weather.sh - Cron wrapper for weather-trader
# Runs weather-trader with production settings, logs output
#
# Cron entry (every 4 hours, 6am-10pm ET):
#   0 6,10,14,18,22 * * * /Users/lacy/repo/simmer-trading/scripts/cron-weather.sh
#
# Or via openclaw cron config

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/weather-$(date '+%Y-%m-%d').log"

# Load API key
if [[ -f "$HOME/.env.simmer" ]]; then
  source "$HOME/.env.simmer"
fi

if [[ -z "${SIMMER_API_KEY:-}" ]]; then
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ERROR: SIMMER_API_KEY not set" >> "$LOG_FILE"
  exit 1
fi

# Production settings
export DRY_RUN=false
export EDGE_PCT_THRESHOLD=15    # 15% relative edge minimum
export TRADE_AMOUNT=80          # $80 SIM per trade
export VENUE=sim                # Paper trading until strategy proves out
export MAX_TRADES=5             # Up to 5 trades per scan
export MIN_PRICE=0.03
export MAX_PRICE=0.80
export MAX_SPREAD_PCT=35
export STOP_LOSS_PCT=0.30
export TAKE_PROFIT_PCT=1.50
export MAX_DAILY_LOSS=400       # $400 SIM daily loss limit

echo "" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"
echo "Cron run: $(date)" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"

"${SCRIPT_DIR}/weather-trader.sh" >> "$LOG_FILE" 2>&1

exit_code=$?
if [[ $exit_code -ne 0 ]]; then
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ERROR: weather-trader exited with code $exit_code" >> "$LOG_FILE"
fi
