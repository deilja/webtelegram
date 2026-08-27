#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.1.0"
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
  if [[ -n "$data" ]]; then
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      -X "$method" -H "Authorization: Bearer $api_token" -H 'Content-Type: application/json' --data "$data" "$url"
  else
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      -X "$method" -H "Authorization: Bearer $api_token" "$url"
  fi
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

make_plan(){
  local external_port=443 xray443_count
  xray443_count="$(jq '[.obj[] | select((.port|tonumber?) == 443)] | length' "$STATE_DIR/inbounds.json")"
  jq --argjson port "$external_port" --argjson count "$xray443_count" \
    '{version:1, external_port:$port, current_inbounds:.obj, current_443_count:$count, action:"DRY_RUN_ONLY", apply:false, warning:"Do not assign multiple public inbounds to the same socket. A single 443 requires explicit transport/routing design."}' \
    "$STATE_DIR/inbounds.json" > "$PLAN_FILE"
  chmod 600 "$PLAN_FILE"
}

validate_xray(){
  if [[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]]; then
    /usr/local/x-ui/bin/xray-linux-amd64 -test -config /usr/local/x-ui/bin/config.json >/dev/null 2>&1 || return 1
    return 0
  fi
  return 2
}

main(){
  log "Automated 3X-UI manager $VERSION"
  prompt_config
  fetch_inbounds
  backup_dir="$(backup)"
  log "Backup: $backup_dir"
  show
  make_plan
  log "Migration plan: $PLAN_FILE"
  log "No inbound changes were applied."
  if ss -lntp 2>/dev/null | grep -E ':(443)[[:space:]]' >/dev/null; then
    log "TCP 443 is currently occupied; no automatic takeover is attempted."
  else
    log "TCP 443 is currently free."
  fi
  if validate_xray; then log "Current Xray configuration: valid"; else log "Current Xray configuration: validation unavailable or failed; no changes made."; fi
  cat <<'EOF'

SAFE MODE:
This release only discovers, backs up and plans. It does not rewrite 3X-UI/Xray inbounds.
The apply phase must be implemented with protocol-aware routing, transactional validation and rollback.
EOF
}

main "$@"
