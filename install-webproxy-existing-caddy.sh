#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
TPROXY_COMMIT="52a5feb7fac38f68da5afef9cedd9b3bfc8473ca"
TPROXY_REPO="https://github.com/telegramdesktop/tproxy-server.git"
REPO_DIR="/root/tproxy-server"
SITE_TARGET="/srv/tproxy-site"
BACKUP_ROOT="/root/webproxy-backups"
CADDYFILE="/etc/caddy/Caddyfile"

log(){ printf '[webproxy] %s\n' "$*"; }
die(){ printf '[webproxy] ERROR: %s\n' "$*" >&2; exit 1; }
valid_domain(){
  local d="$1" label
  [[ ${#d} -le 253 && "$d" == *.* && "$d" != *..* ]] || return 1
  [[ "$d" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
  IFS=. read -r -a labels <<< "$d"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}
valid_email(){ [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]; }
valid_secret(){ [[ "$1" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ "$(uname -m)" == x86_64 ]] || die "Ubuntu 24.04 x86_64 is required."
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || die "Ubuntu 24.04 is required."
command -v systemctl >/dev/null || die "systemd is required."
systemctl is-active --quiet caddy || die "Caddy must already be installed and running."
[[ -f "$CADDYFILE" ]] || die "Caddyfile not found: $CADDYFILE"

read -r -p "New proxy domain: " DOMAIN
DOMAIN="${DOMAIN,,}"
valid_domain "$DOMAIN" || die "Invalid hostname."
read -r -p "ACME email: " EMAIL
valid_email "$EMAIL" || die "Invalid email."
read -r -p "Generate a secure secret automatically? [Y/n]: " MODE
MODE="${MODE:-Y}"
if [[ "$MODE" =~ ^[Yy]$ ]]; then SECRET="$(openssl rand -hex 16)"; else read -r -s -p "Secret (32 lowercase hex, optionally dd + 32 hex): " SECRET; echo; fi
valid_secret "$SECRET" || die "Invalid secret."

for p in 2398 8080; do
  if ss -H -lnt "sport = :$p" 2>/dev/null | grep -q .; then
    ss -H -lntp "sport = :$p" || true
    die "Port $p is already in use. Existing services are not modified."
  fi
done

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git openssl dnsutils nftables build-essential golang-go libssl-dev util-linux zlib1g-dev tar iproute2

A_RECORDS="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)"
[[ -n "$A_RECORDS" ]] || die "No IPv4 A record found for $DOMAIN."
VPS_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
[[ -z "$VPS_IP" || "$A_RECORDS" == *"$VPS_IP"* ]] || die "A record does not point to this VPS."

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
install -d -m 0700 "$BACKUP_DIR"
cp -a "$CADDYFILE" "$BACKUP_DIR/Caddyfile"
if [[ -d /etc/caddy ]]; then tar -C /etc -czf "$BACKUP_DIR/caddy-config.tar.gz" caddy; fi

if [[ -e "$REPO_DIR" ]]; then
  mv -- "$REPO_DIR" "${REPO_DIR}.backup.${STAMP}"
fi
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin "$TPROXY_REPO"
git -C "$REPO_DIR" fetch --depth 1 origin "$TPROXY_COMMIT"
git -C "$REPO_DIR" checkout --detach -q FETCH_HEAD
[[ "$(git -C "$REPO_DIR" rev-parse HEAD)" == "$TPROXY_COMMIT" ]] || die "Pinned tproxy-server verification failed."

for f in deploy/install-mtproxy.sh deploy/mtproxy.service deploy/tproxy-server.service deploy/tproxy-firewall.service deploy/firewall.nft deploy/refresh-mtproxy-config.service deploy/refresh-mtproxy-config.timer deploy/refresh-mtproxy-config.sh; do
  [[ -f "$REPO_DIR/$f" ]] || die "Pinned upstream file is missing: $f"
done

"$REPO_DIR/deploy/install-mtproxy.sh"
id tproxy >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
cd "$REPO_DIR"
go build -trimpath -ldflags='-s -w' -o /usr/local/bin/tproxy-server ./cmd/tproxy-server
chown root:root /usr/local/bin/tproxy-server
chmod 0755 /usr/local/bin/tproxy-server

install -d -o root -g tproxy -m 0750 "$SITE_TARGET"
if [[ -f "$SITE_TARGET/index.html" ]]; then cp -a "$SITE_TARGET/index.html" "$BACKUP_DIR/index.html"; fi
rm -rf -- "${SITE_TARGET:?}"/*
cat > "$SITE_TARGET/index.html" <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Система подключения</title></head><body><main><h1>Подключение</h1><p>Система подготавливает защищённое соединение.</p></main></body></html>
HTML
chown root:tproxy "$SITE_TARGET/index.html"
chmod 0640 "$SITE_TARGET/index.html"

install -d -o root -g tproxy -m 0750 /etc/tproxy-server
cat > /etc/tproxy-server/config.json <<EOF
{"public_hostname":"$DOMAIN","listen":"127.0.0.1:8080","admin_listen":"127.0.0.1:8081","public_dir":"/srv/tproxy-site","profiles_file":"/run/credentials/tproxy-server.service/profiles.json"}
EOF
cat > /etc/tproxy-server/profiles.json <<EOF
{"profiles":[{"name":"default","secret":"$SECRET","backend":"127.0.0.1:2398"}]}
EOF
chown root:tproxy /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
chmod 0640 /etc/tproxy-server/config.json
chmod 0400 /etc/tproxy-server/profiles.json

backend_secret="${SECRET#dd}"
install -d -o root -g mtproxy -m 0750 /etc/mtproxy
cat > /etc/mtproxy/mtproxy.env <<EOF
MTPROXY_SECRET=$backend_secret
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
EOF
chown root:mtproxy /etc/mtproxy/mtproxy.env
chmod 0640 /etc/mtproxy/mtproxy.env

install -m 0644 "$REPO_DIR/deploy/tproxy-server.service" /etc/systemd/system/tproxy-server.service
install -m 0644 "$REPO_DIR/deploy/mtproxy.service" /etc/systemd/system/mtproxy.service
install -m 0644 "$REPO_DIR/deploy/tproxy-firewall.service" /etc/systemd/system/tproxy-firewall.service
install -m 0644 "$REPO_DIR/deploy/refresh-mtproxy-config.service" /etc/systemd/system/refresh-mtproxy-config.service
install -m 0644 "$REPO_DIR/deploy/refresh-mtproxy-config.timer" /etc/systemd/system/refresh-mtproxy-config.timer
install -m 0755 "$REPO_DIR/deploy/refresh-mtproxy-config.sh" /usr/local/sbin/refresh-mtproxy-config
install -m 0644 "$REPO_DIR/deploy/firewall.nft" /etc/tproxy-server/firewall.nft

systemctl daemon-reload
systemctl enable --now tproxy-firewall.service
systemctl enable --now mtproxy.service
for _ in {1..30}; do systemctl is-active --quiet mtproxy && ss -H -lnt "sport = :2398" | grep -q . && break; sleep 1; done
systemctl is-active --quiet mtproxy || die "MTProxy failed to start."
systemctl enable --now tproxy-server.service

FRAGMENT="/etc/caddy/tproxy-$DOMAIN.caddy"
cat > "$FRAGMENT" <<EOF
$DOMAIN {
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
        -Server
    }
    reverse_proxy 127.0.0.1:8080
}
EOF
chmod 0640 "$FRAGMENT"

if grep -Fq "import $FRAGMENT" "$CADDYFILE"; then
  :
else
  printf '\n# XFI Web Proxy — managed by webproxy installer\nimport %s\n' "$FRAGMENT" >> "$CADDYFILE"
fi

caddy validate --config "$CADDYFILE" --adapter caddyfile
systemctl reload caddy
sleep 2
systemctl is-active --quiet caddy || { cp -a "$BACKUP_DIR/Caddyfile" "$CADDYFILE"; systemctl reload caddy || true; die "Caddy reload failed; original Caddyfile restored. Backup: $BACKUP_DIR"; }

log "Installation completed."
log "Domain: $DOMAIN"
log "Caddy fragment: $FRAGMENT"
log "Backup: $BACKUP_DIR"
log "MTProxy secret: $SECRET"
log "No existing web service was stopped or replaced."
