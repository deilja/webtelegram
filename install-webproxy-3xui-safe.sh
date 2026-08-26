#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
WEB_INSTALLER_URL="https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy.sh"
CADDY_INSTALLER_URL="https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy-existing-caddy.sh"
BACKUP_ROOT="/root/webproxy-backups"

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ printf '[webproxy] %s\n' "$*"; }
unit_exists(){ systemctl list-unit-files "$1" >/dev/null 2>&1 && systemctl list-unit-files "$1" 2>/dev/null | grep -q "^${1}[[:space:]]"; }
listener(){ ss -H -lntp "sport = :$1" 2>/dev/null || true; }
listener_process(){ listener "$1" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n1; }

[[ $EUID -eq 0 ]] || die "Run as root."
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || die "Ubuntu 24.04 is required."
[[ "$(uname -m)" == x86_64 ]] || die "Ubuntu 24.04 x86_64 is required."

apt-get update -qq
apt-get install -y --no-install-recommends iproute2 curl ca-certificates >/dev/null

log "Web Proxy installer $VERSION"

XUI_FOUND=0
if unit_exists x-ui.service || unit_exists x-ui; then XUI_FOUND=1; fi
if [[ -d /usr/local/x-ui || -d /opt/3x-ui || -d /etc/x-ui ]]; then XUI_FOUND=1; fi

if (( XUI_FOUND )); then
  log "3X-UI/Xray installation detected."
else
  log "3X-UI/Xray not detected."
fi

for p in 80 443; do
  owner="$(listener_process "$p")"
  if [[ -n "$owner" ]]; then
    printf 'Port %s: %s\n' "$p" "$owner"
    listener "$p"
  else
    printf 'Port %s: free\n' "$p"
  fi
done

XUI_443=0
if (( XUI_FOUND )) && listener 443 | grep -Eiq 'xray|x-ui|3x-ui'; then XUI_443=1; fi
NGINX_443=0
if listener 443 | grep -Eiq 'nginx'; then NGINX_443=1; fi
CADDY_443=0
if listener 443 | grep -Eiq 'caddy'; then CADDY_443=1; fi

printf '\nDetected mode: '
if (( XUI_443 )); then
  echo '3X-UI/Xray owns TCP 443'
elif (( CADDY_443 )); then
  echo 'existing Caddy'
elif (( NGINX_443 )); then
  echo 'existing nginx'
elif listener 443 | grep -q .; then
  echo 'unknown service owns TCP 443'
else
  echo '443 is free'
fi

if (( XUI_443 )); then
  cat >&2 <<'MSG'

SAFE STOP: Xray/3X-UI is already listening on TCP 443.

The installer will NOT:
  - stop Xray or 3X-UI;
  - change an Xray inbound;
  - change the 3X-UI panel port;
  - replace /usr/local/x-ui/bin/config.json;
  - install Caddy on top of the existing 443 listener.

Caddy and Xray cannot both bind the same IPv4/IPv6 TCP 443 socket.
Choose an explicit architecture first:
  1) move Xray behind a reverse proxy and configure the affected inbound;
  2) use another public port for Web Proxy;
  3) use a separate VPS/IP for Web Proxy.

No system changes were made after detection.
MSG
  exit 2
fi

if (( NGINX_443 )); then
  die "nginx owns 443. No automatic nginx modification is performed by this installer. Use the nginx integration separately."
fi

if (( CADDY_443 )); then
  log "Existing Caddy detected. Creating backup and delegating to existing-Caddy installer."
  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"
  if [[ -f /etc/caddy/Caddyfile ]]; then
    cp -a --preserve=mode,ownership /etc/caddy/Caddyfile "$BACKUP_ROOT/Caddyfile.$(date +%Y%m%d-%H%M%S)"
  fi
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$TMP" "$CADDY_INSTALLER_URL"
  chmod 0700 "$TMP"
  exec "$TMP"
fi

if listener 443 | grep -q .; then
  die "TCP 443 is occupied by an unknown service. Refusing to modify the production server."
fi

if (( XUI_FOUND )); then
  log "3X-UI detected, but it does not own TCP 443. Safe clean installation path is available."
fi

log "TCP 443 is free; delegating to the hardened clean installer."
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$TMP" "$WEB_INSTALLER_URL"
chmod 0700 "$TMP"
exec "$TMP"
