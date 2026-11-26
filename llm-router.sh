#!/bin/bash
# LLM Provider Router — Agnes AI <-> Bynara (Gemini) with auto failover
# Simple, dependency-free (curl + python3 stdlib only). Reads keys from env.
#
# Usage:
#   ./llm-router.sh status   # current provider + config summary
#   ./llm-router.sh health   # ping both providers
#   ./llm-router.sh rotate   # manually switch provider
#   ./llm-router.sh test     # send a tiny completion to the active provider
#   ./llm-router.sh auto "prompt"   # route a prompt to whichever provider is healthy

set -euo pipefail

# Load env (optional — keys can also be exported by the caller)
set -a; [ -f /opt/data/.env ] && source /opt/data/.env; set +a

# --- Configuration ----------------------------------------------------------
AGNES_KEY="${AGNES_API_KEY:-}"
AGNES_BASE="${AGNES_BASE_URL:-https://apihub.agnes-ai.com/v1}"
AGNES_MODEL="${AGNES_MODEL:-agnes-2.5-flash}"

BYNARA_KEY="${BYNARA_CKP_API_KEY:-}"
BYNARA_BASE="${BYNARA_BASE_URL:-https://router.bynara.id}"
BYNARA_MODEL="${BYNARA_MODEL:-gemini-3.8-flash-high}"

ROUTER_LOG="${ROUTER_LOG:-/opt/data/logs/router_status.log}"
ROUTER_STATE="${ROUTER_STATE:-/opt/data/state/router_state.json}"
mkdir -p "$(dirname "$ROUTER_LOG")" "$(dirname "$ROUTER_STATE")"

# --- Helpers -----------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$ROUTER_LOG"; }

get_current_provider() {
    if [ -f "$ROUTER_STATE" ]; then
        python3 -c "import json;print(json.load(open('$ROUTER_STATE')).get('provider','agnes'))" 2>/dev/null || echo agnes
    else
        echo agnes
    fi
}

save_state() {
    python3 - "$1" "$ROUTER_STATE" << 'PY'
import json, sys, datetime
provider, path = sys.argv[1], sys.argv[2]
json.dump({"provider": provider, "updated": datetime.datetime.now().isoformat()}, open(path, "w"), indent=2)
PY
}

# Health check: 1-token ping for chat endpoints, /v1/me for router dashboards
check_health() {
    local provider=$1
    case $provider in
        agnes)
            [ -n "$AGNES_KEY" ] || return 1
            curl -sf --max-time 8 -X POST "$AGNES_BASE/chat/completions" \
                -H "Authorization: Bearer $AGNES_KEY" \
                -H "Content-Type: application/json" \
                -d "{\"model\":\"$AGNES_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
                > /dev/null
            ;;
        bynara)
            [ -n "$BYNARA_KEY" ] || return 1
            curl -sf --max-time 8 "$BYNARA_BASE/v1/me" \
                -H "Authorization: Bearer $BYNARA_KEY" > /dev/null
            ;;
    esac
}

provider_is_healthy() {
    local preferred=$1 fallback=$2
    if check_health "$preferred"; then echo "$preferred"; return 0; fi
    if check_health "$fallback";   then echo "$fallback"; return 0; fi
    echo "$preferred"   # both down: still answer with preferred, caller decides
    return 1
}

# --- Commands ----------------------------------------------------------------
status() {
    echo "=== LLM Router Status ==="
    echo "Current Provider: $(get_current_provider)"
    echo ""
    echo "Providers:"
    echo "  1. Agnes AI  ($AGNES_MODEL)  - PRIMARY   [$AGNES_BASE]"
    echo "  2. Bynara    ($BYNARA_MODEL) - FALLBACK  [$BYNARA_BASE]"
    echo ""
    echo "Recent Logs:"
    [ -f "$ROUTER_LOG" ] && tail -5 "$ROUTER_LOG" || echo "  (empty)"
}

rotate() {
    local current; current=$(get_current_provider)
    log "Rotating from $current..."
    if [ "$current" = "agnes" ]; then
        save_state bynara; log "Switched to Bynara (Gemini)"
        echo "Active provider: bynara (Gemini)"
    else
        save_state agnes; log "Fallback to Agnes"
        echo "Active provider: agnes"
    fi
}

health_check() {
    echo "=== Health Check ==="
    if [ -n "$AGNES_KEY" ]; then
        check_health agnes && echo "✓ Agnes AI: HEALTHY" || echo "✗ Agnes AI: UNHEALTHY"
    else
        echo "⚠ Agnes AI: NO KEY CONFIGURED"
    fi
    if [ -n "$BYNARA_KEY" ]; then
        check_health bynara && echo "✓ Bynara: HEALTHY" || echo "✗ Bynara: UNHEALTHY"
    else
        echo "⚠ Bynara: NO KEY CONFIGURED"
    fi
}

test_provider() {
    local provider; provider=$(get_current_provider)
    log "Testing provider: $provider"
    case $provider in
        agnes)
            curl -s --max-time 15 -X POST "$AGNES_BASE/chat/completions" \
                -H "Authorization: Bearer $AGNES_KEY" \
                -H "Content-Type: application/json" \
                -d "{\"model\":\"$AGNES_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Test routing\"}],\"max_tokens\":10}" | head -c 300
            ;;
        bynara)
            curl -s --max-time 15 -X POST "$BYNARA_BASE/v1/chat/completions" \
                -H "Authorization: Bearer $BYNARA_KEY" \
                -H "Content-Type: application/json" \
                -d "{\"model\":\"$BYNARA_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Test routing\"}],\"max_tokens\":10}" | head -c 300
            ;;
    esac
    echo ""
}

# auto: send a chat completion to the first healthy provider
auto_route() {
    local prompt=${1:-"ping"}
    local chosen; chosen=$(provider_is_healthy agnes bynara) || true
    save_state "$chosen"
    log "auto route -> $chosen"
    local base key model
    if [ "$chosen" = "agnes" ]; then base=$AGNES_BASE; key=$AGNES_KEY; model=$AGNES_MODEL
    else base="$BYNARA_BASE/v1"; key=$BYNARA_KEY; model=$BYNARA_MODEL; fi
    curl -s --max-time 30 -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "import json,sys;print(json.dumps({'model':sys.argv[1],'messages':[{'role':'user','content':sys.argv[2]}],'max_tokens':512}))" "$model" "$prompt")"
    echo ""
}

case "${1:-status}" in
    status) status ;;
    rotate) rotate ;;
    health) health_check ;;
    test)   test_provider ;;
    auto)   shift; auto_route "${1:-ping}" ;;
    *) echo "Usage: $0 {status|rotate|health|test|auto <prompt>}"; exit 1 ;;
esac
