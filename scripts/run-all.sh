#!/usr/bin/env bash
set -euo pipefail

# run-all.sh - Run all strategies + position monitor in sequence
# SIM-only until proven profitable
#
# Usage: ./run-all.sh
# Cron:  */5 * * * * SIMMER_API_KEY=sk_live_... /path/to/run-all.sh >> /path/to/logs/run-all.log 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOG_DIR"

DATESTAMP=$(date +%Y%m%d)
LOG_FILE="${LOG_DIR}/run-all-${DATESTAMP}.log"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"
}

log "=========================================="
log "=== Run-All starting ==="
log "=========================================="

# Force SIM venue until we're confident
export VENUE="${VENUE:-sim}"
export DRY_RUN="${DRY_RUN:-false}"

# 1. Position monitor first (manage existing positions)
log "--- Running position monitor ---"
"$SCRIPT_DIR/position-monitor.sh" 2>&1 | tee -a "$LOG_FILE" || {
  log "WARN: Position monitor failed"
}

# 2. Weather trader
log "--- Running weather trader ---"
"$SCRIPT_DIR/weather-trader.sh" 2>&1 | tee -a "$LOG_FILE" || {
  log "WARN: Weather trader failed"
}

# 3. AI divergence
log "--- Running AI divergence ---"
"$SCRIPT_DIR/ai-divergence.sh" 2>&1 | tee -a "$LOG_FILE" || {
  log "WARN: AI divergence failed"
}

# 4. Fast loop (only during market hours for BTC - always open)
log "--- Running fast loop ---"
"$SCRIPT_DIR/fast-loop.sh" 2>&1 | tee -a "$LOG_FILE" || {
  log "WARN: Fast loop failed"
}

# 5. Log portfolio summary
log "--- Portfolio Summary ---"
PORTFOLIO=$("$SCRIPT_DIR/simmer.sh" GET /api/sdk/positions 2>/dev/null) || {
  log "ERROR: Failed to fetch portfolio"
  exit 0
}

TOTAL_POSITIONS=$(echo "$PORTFOLIO" | jq '.positions | length' 2>/dev/null || echo 0)
TOTAL_VALUE=$(echo "$PORTFOLIO" | jq '[.positions[].current_value] | add // 0' 2>/dev/null || echo 0)
TOTAL_COST=$(echo "$PORTFOLIO" | jq '[.positions[].cost_basis] | add // 0' 2>/dev/null || echo 0)
TOTAL_PNL=$(echo "$PORTFOLIO" | jq '[.positions[].pnl] | add // 0' 2>/dev/null || echo 0)

SIM_PNL=$(echo "$PORTFOLIO" | jq '[.positions[] | select(.venue == "sim") | .pnl] | add // 0' 2>/dev/null || echo 0)
POLY_PNL=$(echo "$PORTFOLIO" | jq '[.positions[] | select(.venue == "polymarket") | .pnl] | add // 0' 2>/dev/null || echo 0)

log "Positions: $TOTAL_POSITIONS | Value: \$$TOTAL_VALUE | Cost: \$$TOTAL_COST | P&L: \$$TOTAL_PNL"
log "SIM P&L: \$$SIM_PNL | Polymarket P&L: \$$POLY_PNL"

# Append to daily tracking CSV
TRACK_FILE="${LOG_DIR}/track-${DATESTAMP}.csv"
if [[ ! -f "$TRACK_FILE" ]]; then
  echo "timestamp,positions,value,cost,pnl,sim_pnl,poly_pnl" > "$TRACK_FILE"
fi
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$TOTAL_POSITIONS,$TOTAL_VALUE,$TOTAL_COST,$TOTAL_PNL,$SIM_PNL,$POLY_PNL" >> "$TRACK_FILE"

log "=== Run-All finished ==="
