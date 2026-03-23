#!/usr/bin/env bash
# simmer.sh — thin wrapper around Simmer's REST API
# Usage: simmer METHOD PATH [JSON_BODY]
#   simmer GET /api/sdk/agents/me
#   simmer POST /api/sdk/trades '{"market_id":"...","side":"yes","amount":10}'
#
# Requires: SIMMER_API_KEY
# Optional: SIMMER_BASE_URL (default: https://api.simmer.markets)

set -euo pipefail

: "${SIMMER_API_KEY:?Set SIMMER_API_KEY}"
BASE="${SIMMER_BASE_URL:-https://api.simmer.markets}"

METHOD="${1:?Usage: simmer METHOD PATH [JSON_BODY]}"
ENDPOINT="${2:?Usage: simmer METHOD PATH [JSON_BODY]}"
BODY="${3:-}"

URL="${BASE}${ENDPOINT}"

ARGS=(
  -s -w '\n%{http_code}'
  -X "$METHOD"
  -H "Authorization: Bearer $SIMMER_API_KEY"
  -H "Content-Type: application/json"
)

if [[ -n "$BODY" ]]; then
  ARGS+=(-d "$BODY")
fi

RESPONSE=$(curl "${ARGS[@]}" "$URL")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY_OUT=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ge 400 ]]; then
  echo "HTTP $HTTP_CODE" >&2
  echo "$BODY_OUT" | jq . 2>/dev/null || echo "$BODY_OUT" >&2
  exit 1
fi

echo "$BODY_OUT" | jq . 2>/dev/null || echo "$BODY_OUT"
