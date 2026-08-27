#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
BACKUP_ROOT="/root/webproxy-backups"
STATE_DIR="/etc/webproxy"
ENV_FILE="$STATE_DIR/3xui.env"

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

api_url=""
api_token=""
base_path=""

load_env(){
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    api_url="${XUI_API_URL:-}"
    api_token="${XUI_API_TOKEN:-}"
    base_path="${XUI_BASE_PATH:-}"
  fi
}

save_env(){
  umask 077
  cat > "$ENV_FILE" <<EOF
XUI_API_URL=$(printf '%q' "$api_url")
XUI_API_TOKEN=$(printf '%q' "$api_token")
XUI_BASE_PATH=$(printf '%q' "$base_path")
EOF
  chmod 600 "$ENV_FILE"
}

prompt_config(){
  load_env
  [[ -n "$api_url" ]] || read -r -p '3X-UI API URL (e.g. https://host/panel/api): ' api_url
  [[ -n "$api_token" ]] || { read -r -s -p '3X-UI API token: ' api_token; echo; }
  [[ -n "$api_url" && -n "$api_token" ]] || die "API URL and token are required."
  save_env
}

api(){
  local method="$1" path="$2" data="${3:-}"
  local url="${api_url%/}${path}"
  if [[ -n "$data" ]]; then
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      -X "$method" -H "Authorization: Bearer $api_token" -H 'Content-Type: application/json' \
      --data "$data" "$url"
  else
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      -X "$method" -H "Authorization: Bearer $api_token" "$url"
  fi
}

check_api(){
  local r
  r="$(api GET /inbounds/list)" || die "3X-UI API request failed. Check URL/token."
  jq -e '.success == true and (.obj | type == "array")' >/dev/null <<<"$r" || die "3X-UI returned an unexpected response."
  printf '%s\n' "$r" > /tmp/xfi-3xui-inbounds.json
}

backup(){
  local ts dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$BACKUP_ROOT/3xui-$ts"
  mkdir -p "$dir"
  chmod 700 "$dir"
  cp -a /usr/local/x-ui/bin/config.json "$dir/xray-config.json" 2>/dev/null || true
  cp -a "$ENV_FILE" "$dir/3xui.env" 2>/dev/null || true
  cp -a /usr/local/x-ui/db/x-ui.db "$dir/x-ui.db" 2>/dev/null || true
  cp /tmp/xfi-3xui-inbounds.json "$dir/inbounds.json"
  sha256sum "$dir"/* > "$dir/SHA256SUMS" 2>/dev/null || true
  printf '%s\n' "$dir"
}

show(){
  jq -r '.obj[] | [(.id // "-"),(.remark // "-"),(.protocol // "-"),(.port // "-"),((.listen // "0.0.0.0")|tostring)] | @tsv' /tmp/xfi-3xui-inbounds.json \
    | { printf 'ID\tREMARK\tPROTOCOL\tPORT\tLISTEN\n'; cat; }
}

safe_plan(){
  log 'Analysing current inbounds; no changes will be made.'
  local count
  count="$(jq '.obj | length' /tmp/xfi-3xui-inbounds.json)"
  printf '\nFound inbounds: %s\n\n' "$count"
  show
  printf '\nIMPORTANT: multiple Xray inbounds cannot simply be assigned the same public IP:443.\n'
  printf 'The manager will NOT blindly rewrite ports or transports.\n'
  printf 'A single external 443 requires a deliberate routing/reverse-proxy design.\n\n'
}

status(){
  log 'Checking local Xray/3X-UI state.'
  systemctl is-active x-ui 2>/dev/null || true
  ss -lntp | grep -E ':(80|443)[[:space:]]' || true
}

main(){
  log "Automated 3X-UI manager $VERSION"
  prompt_config
  check_api
  backup_dir="$(backup)"
  log "Backup: $backup_dir"
  safe_plan
  status
  cat <<'EOF'

No inbound changes were applied.

Next actions are intentionally explicit:
  1) create a single-443 migration plan
  2) review the plan
  3) apply only approved inbound changes
  4) validate Xray
  5) rollback automatically on failure
EOF
}

main "$@"
