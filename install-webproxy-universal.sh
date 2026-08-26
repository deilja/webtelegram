#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Pinned release of this repository. Update this value when publishing a new installer release.
PROJECT_COMMIT="8f67694335480422d7bb070f7d65368242bb3f61"
RAW_BASE="https://raw.githubusercontent.com/deilja/webtelegram/${PROJECT_COMMIT}"
TMP_DIR="$(mktemp -d /tmp/webproxy-universal.XXXXXX)"
trap 'rm -rf -- "${TMP_DIR:?}"' EXIT

die(){ printf '[webproxy] ERROR: %s\n' "$*" >&2; exit 1; }
log(){ printf '[webproxy] %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ "$(uname -m)" == "x86_64" ]] || die "Ubuntu 24.04 x86_64 is required."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 is required."
command -v systemctl >/dev/null 2>&1 || die "systemd is required."
command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y --no-install-recommends ca-certificates curl; }

# Detect an existing HTTP stack before downloading/running the real installer.
CADDY_ACTIVE=0
NGINX_ACTIVE=0
if systemctl is-active --quiet caddy 2>/dev/null && [[ -f /etc/caddy/Caddyfile ]]; then
  CADDY_ACTIVE=1
fi
if systemctl is-active --quiet nginx 2>/dev/null; then
  NGINX_ACTIVE=1
fi

if (( NGINX_ACTIVE )); then
  die "nginx is already running. Existing nginx is not modified by this installer. Use the nginx integration workflow instead."
fi

if (( CADDY_ACTIVE )); then
  SCRIPT="install-webproxy-existing-caddy.sh"
  log "Existing Caddy detected: using safe existing-Caddy integration."
else
  if systemctl list-unit-files caddy.service >/dev/null 2>&1 && systemctl list-unit-files caddy.service | grep -q '^caddy.service'; then
    die "Caddy is installed but not running. Start and verify Caddy first, or remove the unused Caddy installation."
  fi
  SCRIPT="install-webproxy.sh"
  log "No active Caddy detected: using clean VPS installer."
fi

DEST="$TMP_DIR/$SCRIPT"
log "Downloading pinned installer $SCRIPT from project commit $PROJECT_COMMIT"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  -o "$DEST" "$RAW_BASE/$SCRIPT"
chmod 0700 "$DEST"

bash -n "$DEST"
"$DEST"
