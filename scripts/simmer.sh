#!/usr/bin/env bash
set -euo pipefail

# simmer.sh - Helper script for Simmer Markets API
# Usage: simmer METHOD PATH [JSON_BODY]
# Examples:
#   simmer GET /api/sdk/agents/me
#   simmer POST /api/sdk/trade '{"market_id":"abc","side":"yes","amount":10}'
#   simmer GET "/api/sdk/markets?q=weather&limit=5"

BASE_URL="${SIMMER_BASE_URL:-https://api.simmer.markets}"

if [[ -z "${SIMMER_API_KEY:-}" ]]; then
  echo "ERROR: SIMMER_API_KEY is not set" >&2
  echo "Export it: export SIMMER_API_KEY=\"sk_live_...\"" >&2
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "ERROR: curl is required but not found" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not found" >&2
  exit 1
fi

usage() {
  echo "Usage: simmer METHOD PATH [JSON_BODY]"
  echo ""
  echo "Methods: GET, POST, PUT, PATCH, DELETE"
  echo ""
  echo "Examples:"
  echo "  simmer GET /api/sdk/agents/me"
  echo "  simmer GET '/api/sdk/markets?q=weather&limit=5'"
  echo "  simmer POST /api/sdk/trade '{\"market_id\":\"abc\",\"side\":\"yes\",\"amount\":10}'"
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

METHOD="${1^^}"
PATH_ARG="$2"
BODY="${3:-}"

# Build URL (handle paths with or without leading slash)
if [[ "$PATH_ARG" == /* ]]; then
  URL="${BASE_URL}${PATH_ARG}"
else
  URL="${BASE_URL}/${PATH_ARG}"
fi

# Build curl args
CURL_ARGS=(
  -s
  -X "$METHOD"
  -H "Authorization: Bearer ${SIMMER_API_KEY}"
  -H "Content-Type: application/json"
  --max-time 30
)

if [[ -n "$BODY" ]]; then
  CURL_ARGS+=(-d "$BODY")
fi

# Make request, format with jq, handle errors
HTTP_CODE=$(curl "${CURL_ARGS[@]}" -w "\n%{http_code}" "$URL")
RESPONSE_BODY=$(echo "$HTTP_CODE" | sed '$d')
STATUS=$(echo "$HTTP_CODE" | tail -1)

if [[ "$STATUS" -ge 400 ]]; then
  echo "ERROR: HTTP $STATUS" >&2
  echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY" >&2
  exit 1
fi

echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
