#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.2.0"
BACKUP_ROOT="/root/webproxy-backups"
STATE_DIR="/etc/webproxy"
ENV_FILE="$STATE_DIR/3xui.env"
PLAN_FILE="$STATE_DIR/3xui-migration-plan.json"

log(){ printf '[xfi-3xui] %s\n' "$*"; }
die(){ printf '[xfi-3xui] ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

[[ $EUID -eq 0 ]] || die "Run as root."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 is required."
[[ "$(uname -m)" == "x86_64" ]] || die "x86_64 is required."
for c in curl jq ss sha256sum systemctl; do need "$c"; done
mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
chmod 700 "$STATE_DIR" "$BACKUP_ROOT"

api_url="${XUI_API_URL:-}"
api_token="${XUI_API_TOKEN:-}"
mode="${1:-plan}"

load_env(){
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    api_url="${XUI_API_URL:-$api_url}"
    api_token="${XUI_API_TOKEN:-$api_token}"
  fi
}

save_env(){
  umask 077
  cat > "$ENV_FILE" <<EOF
XUI_API_URL=$(printf '%q' "$api_url")
XUI_API_TOKEN=$(printf '%q' "$api_token")
EOF
  chmod 600 "$ENV_FILE"
}

prompt_config(){
  load_env
  [[ -n "$api_url" ]] || read -r -p '3X-UI API URL (e.g. https://host/panel/api): ' api_url
  [[ -n "$api_token" ]] || { read -r -s -p '3X-UI API token: ' api_token; echo; }
  [[ -n "$api_url" && -n "$api_token" ]] || die "API URL and token are required."
  [[ "$api_url" =~ ^https:// ]] || die "HTTPS is required for the 3X-UI API URL."
  save_env
}

api(){
  local method="$1" path="$2" data="${3:-}"
  local url="${api_url%/}${path}"
  local args=(--fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 -X "$method" -H "Authorization: Bearer $api_token")
  [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' --data "$data")
  curl "${args[@]}" "$url"
}

fetch_inbounds(){
  local r
  r="$(api GET /inbounds/list)" || die "3X-UI API request failed. Check URL/token."
  jq -e '.success == true and (.obj | type == "array")' >/dev/null <<<"$r" || die "Unexpected 3X-UI API response."
  printf '%s\n' "$r" > "$STATE_DIR/inbounds.json"
  chmod 600 "$STATE_DIR/inbounds.json"
}

backup(){
  local ts dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$BACKUP_ROOT/3xui-$ts"
  mkdir -p "$dir"; chmod 700 "$dir"
  cp -a /usr/local/x-ui/bin/config.json "$dir/xray-config.json" 2>/dev/null || true
  cp -a /usr/local/x-ui/db/x-ui.db "$dir/x-ui.db" 2>/dev/null || true
  cp -a "$ENV_FILE" "$dir/3xui.env" 2>/dev/null || true
  cp -a "$STATE_DIR/inbounds.json" "$dir/inbounds.json"
  sha256sum "$dir"/* > "$dir/SHA256SUMS" 2>/dev/null || true
  printf '%s\n' "$dir"
}

show(){
  printf '\n%-8s %-28s %-10s %-8s %-18s\n' ID REMARK PROTOCOL PORT LISTEN
  jq -r '.obj[] | [(.id // "-"),(.remark // "-"),(.protocol // "-"),(.port // "-"),(.listen // "0.0.0.0")] | @tsv' "$STATE_DIR/inbounds.json"
}

classify(){
  jq '[.obj[] | {
    id,
    remark,
    protocol,
    port,
    listen:(.listen // "0.0.0.0"),
    streamSettings:(.streamSettings // {}),
    security:((.streamSettings // {}).security // "none"),
    network:((.streamSettings // {}).network // "tcp")
  }] | map(. + {risk:(
    if .security == "reality" then "HIGH_REALITY"
    elif .network == "ws" and .security == "tls" then "CADDY_WS_TLS_CANDIDATE"
    elif .network == "grpc" and .security == "tls" then "GRPC_REQUIRES_EXPLICIT_ROUTING"
    elif .network == "tcp" and (.security == "tls" or .security == "none") then "TCP_REQUIRES_EXPLICIT_ROUTING"
    else "REVIEW_REQUIRED" end
  )})' "$STATE_DIR/inbounds.json" > "$STATE_DIR/classified.json"
  chmod 600 "$STATE_DIR/classified.json"
}

make_plan(){
  local external_port=443 xray443_count safe_candidates unsafe
  xray443_count="$(jq '[.obj[] | select((.port|tonumber?) == 443)] | length' "$STATE_DIR/inbounds.json")"
  safe_candidates="$(jq '[.[] | select(.risk == "CADDY_WS_TLS_CANDIDATE")] | length' "$STATE_DIR/classified.json")"
  unsafe="$(jq '[.[] | select(.risk != "CADDY_WS_TLS_CANDIDATE")] | length' "$STATE_DIR/classified.json")"
  jq --argjson port "$external_port" --argjson count "$xray443_count" --argjson candidates "$safe_candidates" --argjson unsafe "$unsafe" \
    '{version:2, external_port:$port, current_inbounds:.obj, classified:(input), current_443_count:$count, caddy_ws_tls_candidates:$candidates, review_required:$unsafe, action:"PLAN_ONLY", apply_allowed:false, reasons:["Multiple public inbounds cannot share one socket.","Reality/RAW TCP/GRPC require explicit protocol-aware routing.","Standard Caddy cannot proxy arbitrary Xray TCP/Reality inbounds without a suitable layer-4 design."]}' \
    "$STATE_DIR/inbounds.json" "$STATE_DIR/classified.json" > "$PLAN_FILE"
  chmod 600 "$PLAN_FILE"
}

validate_xray(){
  if [[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]]; then
    /usr/local/x-ui/bin/xray-linux-amd64 -test -config /usr/local/x-ui/bin/config.json >/dev/null 2>&1 || return 1
    return 0
  fi
  return 2
}

status(){
  log 'Local listeners:'
  ss -lntp 2>/dev/null | grep -E ':(80|443)[[:space:]]' || true
  log 'x-ui:'
  systemctl is-active x-ui 2>/dev/null || true
}

apply_guard(){
  die "APPLY is intentionally blocked until a protocol-specific routing plan has been generated and approved. Use: $0 plan"
}

main(){
  case "$mode" in
    plan|apply) ;;
    *) die "Usage: $0 [plan|apply]" ;;
  esac
  log "Automated 3X-UI manager $VERSION ($mode)"
  prompt_config
  fetch_inbounds
  backup_dir="$(backup)"
  log "Backup: $backup_dir"
  show
  classify
  make_plan
  log "Migration plan: $PLAN_FILE"
  status
  if validate_xray; then log "Current Xray configuration: valid"; else log "Current Xray configuration: validation unavailable or failed; no changes made."; fi
  if [[ "$mode" == "apply" ]]; then apply_guard; fi
  log "No inbound changes were applied."
}

main "$@"
