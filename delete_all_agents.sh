#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Cursor Cloud Agents: List & Delete All Agents
# Reference: https://cursor.com/docs/cloud-agent/api/endpoints
# ==============================================================================

BASE_URL="${CURSOR_API_BASE_URL:-https://api.cursor.com}"
API_KEY="${CURSOR_API_KEY:-}"
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/cursor_agents_$(date +%Y%m%d_%H%M%S).log}"

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=true ;;
    --help|-h)
      echo "Usage: CURSOR_API_KEY=<key> $0 [--dry-run]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg (use --help)" >&2
      exit 1
      ;;
  esac
done

log() {
  printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"
}

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { log "ERROR: '$cmd' is required."; exit 1; }
done

if [[ -z "$API_KEY" ]]; then
  log "ERROR: CURSOR_API_KEY is not set."
  exit 1
fi

# ------------------------------------------------------------------------------
# Step 1: List all Cloud Agents
# ------------------------------------------------------------------------------
log "Step 1/2: Listing agents..."

ALL_AGENTS_JSON="[]"
CURSOR=""

while true; do
  URL="${BASE_URL}/v1/agents?limit=100&includeArchived=true${CURSOR:+&cursor=$CURSOR}"
  RESPONSE_FILE=$(mktemp)

  HTTP_STATUS=$(curl -sS -w "%{http_code}" -o "$RESPONSE_FILE" \
    --request GET --url "$URL" -u "${API_KEY}:") || {
      log "ERROR: Network failure on GET /v1/agents"
      rm -f "$RESPONSE_FILE"
      exit 1
    }

  if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
    log "ERROR: GET /v1/agents failed (HTTP $HTTP_STATUS): $(cat "$RESPONSE_FILE")"
    rm -f "$RESPONSE_FILE"
    exit 1
  fi

  PAGE_ITEMS=$(jq -c '.items // []' "$RESPONSE_FILE")
  NEXT_CURSOR=$(jq -r '.nextCursor // empty' "$RESPONSE_FILE")
  rm -f "$RESPONSE_FILE"

  ALL_AGENTS_JSON=$(jq -c -n --argjson cur "$ALL_AGENTS_JSON" --argjson page "$PAGE_ITEMS" '$cur + $page')
  [[ -z "$NEXT_CURSOR" ]] && break
  CURSOR="$NEXT_CURSOR"
done

TOTAL=$(echo "$ALL_AGENTS_JSON" | jq 'length')
ARCHIVED=$(echo "$ALL_AGENTS_JSON" | jq '[.[] | select(.status == "ARCHIVED")] | length')
ACTIVE=$((TOTAL - ARCHIVED))

log "Found ${TOTAL} agent(s) (archived: ${ARCHIVED}, non-archived: ${ACTIVE})"

if [[ "$TOTAL" -gt 0 ]]; then
  while IFS=$'\t' read -r id status archived name; do
    log "  - ${id} | status=${status} | archived=${archived} | ${name}"
  done < <(
    echo "$ALL_AGENTS_JSON" | jq -r '.[] | [
      .id,
      (.status // "UNKNOWN"),
      (if .status == "ARCHIVED" then "yes" else "no" end),
      (.name // "(unnamed)")
    ] | @tsv'
  )
fi

# ------------------------------------------------------------------------------
# Step 2: Delete all Cloud Agents
# ------------------------------------------------------------------------------
DELETED=0
FAILED=0

if [[ "$TOTAL" -eq 0 ]]; then
  log "Step 2/2: No agents to delete."
elif [[ "$DRY_RUN" == "true" ]]; then
  log "Step 2/2: Dry-run enabled, skipped deleting ${TOTAL} agent(s)."
else
  log "Step 2/2: Deleting ${TOTAL} agent(s)..."
  while IFS=$'\t' read -r id; do
    DEL_RESP=$(mktemp)
    DEL_STATUS=$(curl -sS -w "%{http_code}" -o "$DEL_RESP" \
      --request DELETE --url "${BASE_URL}/v1/agents/${id}" -u "${API_KEY}:") || DEL_STATUS="000"

    if [[ "$DEL_STATUS" -ge 200 && "$DEL_STATUS" -lt 300 ]]; then
      DELETED=$((DELETED + 1))
      log "  - Deleted ${id}"
    else
      FAILED=$((FAILED + 1))
      log "  - FAILED ${id} (HTTP ${DEL_STATUS}): $(cat "$DEL_RESP" 2>/dev/null || true)"
    fi
    rm -f "$DEL_RESP"
  done < <(echo "$ALL_AGENTS_JSON" | jq -r '.[].id')
fi

# ------------------------------------------------------------------------------
# Final Log
# ------------------------------------------------------------------------------
log "Done: total=${TOTAL} (archived=${ARCHIVED}, non_archived=${ACTIVE}), deleted=${DELETED}, failed=${FAILED} | log=${LOG_FILE#$SCRIPT_DIR/}"

[[ "$FAILED" -eq 0 ]]
