#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="2.1.0"
TPROXY_COMMIT="52a5feb7fac38f68da5afef9cedd9b3bfc8473ca"
TPROXY_REPO="https://github.com/telegramdesktop/tproxy-server.git"
REPO_DIR="/root/tproxy-server"
SITE_INPUT="/opt/tproxy-site"
SITE_TARGET="/srv/tproxy-site"

 die(){ echo "ERROR: $*" >&2; exit 1; }
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
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
port_listener(){ ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }
port_owner(){ ss -H -lntp "sport = :$1" 2>/dev/null || true; }
require_free(){ local p="$1"; if port_listener "$p"; then port_owner "$p"; die "Port $p is already in use. Stop the conflicting service first."; fi; }
cleanup_tmp(){ rm -f "${CADDY_ARCHIVE:-}" "${TPROXY_ARCHIVE:-}"; rm -rf "${CADDY_DIR:-}" "${TPROXY_DIR:-}"; }
trap cleanup_tmp EXIT

[[ $EUID -eq 0 ]] || die "Run as root."
[[ "$(uname -m)" == x86_64 ]] || die "Ubuntu 24.04 x86_64 is required."
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || die "Ubuntu 24.04 is required."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git openssl dnsutils nftables build-essential golang-go libssl-dev util-linux zlib1g-dev tar iproute2

while true; do
  read -r -p "Domain (example: proxy.example.com): " DOMAIN
  DOMAIN="${DOMAIN,,}"; DOMAIN="$(trim "$DOMAIN")"
  valid_domain "$DOMAIN" && break || echo "Invalid hostname."
done
while true; do
  read -r -p "ACME email: " EMAIL
  EMAIL="$(trim "$EMAIL")"
  valid_email "$EMAIL" && break || echo "Invalid email."
done
read -r -p "Generate a secure secret automatically? [Y/n]: " MODE
MODE="$(trim "${MODE:-Y}")"
if [[ -z "$MODE" || "$MODE" =~ ^[Yy]$ ]]; then
  SECRET="$(openssl rand -hex 16)"
else
  while true; do
    read -r -s -p "Secret (32 lowercase hex, optionally dd + 32 hex): " SECRET; echo
    valid_secret "$SECRET" && break || echo "Invalid secret."
  done
fi
valid_secret "$SECRET" || die "Invalid secret."

# This installer is production-safe but intentionally does not take ownership of an existing HTTP stack.
for p in 80 443 2398 8080 8081; do require_free "$p"; done
if systemctl list-unit-files caddy.service 2>/dev/null | grep -q '^caddy.service'; then
  die "Caddy is already installed. Use a dedicated VPS or configure the existing Caddy deployment manually."
fi
if systemctl list-unit-files 'nginx.service' 2>/dev/null | grep -q '^nginx.service'; then
  die "nginx is installed. Use a dedicated VPS or configure nginx manually."
fi

A_RECORDS="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)"
[[ -n "$A_RECORDS" ]] || die "No IPv4 A record found for $DOMAIN."
VPS_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
if [[ -n "$VPS_IP" ]] && ! grep -Fxq "$VPS_IP" <<< "$A_RECORDS"; then
  echo "DNS A records:"; printf '%s\n' "$A_RECORDS"; echo "VPS IPv4: $VPS_IP"
  die "DNS does not point to this VPS."
fi
if getent ahostsv6 "$DOMAIN" >/dev/null 2>&1; then
  IPV6="$(getent ahostsv6 "$DOMAIN" | awk '{print $1}' | sort -u | head -n1 || true)"
  if [[ -n "$IPV6" ]]; then
    PUBLIC_IPV6="$(curl -6fsS --max-time 10 https://api6.ipify.org || true)"
    [[ -z "$PUBLIC_IPV6" || "$IPV6" == "$PUBLIC_IPV6" ]] || die "AAAA record does not point to this VPS."
  fi
fi

# Never destroy an old checkout. Keep a timestamped backup before replacing it.
if [[ -e "$REPO_DIR" ]]; then
  BACKUP_DIR="${REPO_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
  mv -- "$REPO_DIR" "$BACKUP_DIR"
  echo "Previous source checkout moved to $BACKUP_DIR"
fi
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin "$TPROXY_REPO"
git -C "$REPO_DIR" fetch --depth 1 origin "$TPROXY_COMMIT"
git -C "$REPO_DIR" checkout --detach -q FETCH_HEAD
[[ "$(git -C "$REPO_DIR" rev-parse HEAD)" == "$TPROXY_COMMIT" ]] || die "Pinned tproxy-server commit verification failed."

for f in deploy/install-mtproxy.sh deploy/mtproxy.service deploy/tproxy-server.service deploy/tproxy-firewall.service deploy/firewall.nft deploy/refresh-mtproxy-config.service deploy/refresh-mtproxy-config.timer deploy/refresh-mtproxy-config.sh deploy/Caddyfile deploy/caddy.service; do
  [[ -f "$REPO_DIR/$f" ]] || die "Pinned upstream file is missing: $f"
done

mkdir -p "$SITE_INPUT"
cat > "$SITE_INPUT/index.html" <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Система подключения</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#080b11;color:#f5f7fb;font:16px system-ui}.card{width:min(620px,calc(100% - 40px));padding:36px;border:1px solid #252d3a;border-radius:24px;background:#101620;text-align:center;box-shadow:0 25px 80px #0008}h1{font-size:42px;margin:0 0 14px}.muted{color:#8995a8;line-height:1.7}.status{display:inline-block;margin-bottom:24px;padding:8px 13px;border-radius:99px;background:#123b2b;color:#8ff0bb;font-size:12px;letter-spacing:.08em}.bar{height:8px;margin:28px 0;background:#202735;border-radius:99px;overflow:hidden}.bar:after{content:"";display:block;width:35%;height:100%;background:#72e6ff;animation:p 1.6s infinite}@keyframes p{to{transform:translateX(300%)}}@media(prefers-reduced-motion:reduce){.bar:after{animation:none}}</style></head><body><main class="card"><div class="status">SYSTEM ONLINE</div><h1>Подключение</h1><p class="muted">Система подготавливает защищённое соединение. Пожалуйста, оставайтесь на этой странице.</p><div class="bar"></div></main></body></html>
HTML
chmod 0755 "$SITE_INPUT"; chmod 0644 "$SITE_INPUT/index.html"

MTPROXY_INSTALL="$REPO_DIR/deploy/install-mtproxy.sh"
chmod 0755 "$MTPROXY_INSTALL"
"$MTPROXY_INSTALL"

id tproxy >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
cd "$REPO_DIR"
go version
go build -trimpath -ldflags='-s -w' -o /usr/local/bin/tproxy-server ./cmd/tproxy-server
chown root:root /usr/local/bin/tproxy-server; chmod 0755 /usr/local/bin/tproxy-server

install -d -o root -g tproxy -m 0750 "$SITE_TARGET"
# SITE_TARGET is a fixed absolute path and the parameter expansion prevents an empty-path rm.
rm -rf -- "${SITE_TARGET:?}"/*
cp -a "$SITE_INPUT/." "$SITE_TARGET/"
chown -R root:tproxy "$SITE_TARGET"
find "$SITE_TARGET" -type d -exec chmod 0750 {} +
find "$SITE_TARGET" -type f -exec chmod 0640 {} +

install -d -o root -g tproxy -m 0750 /etc/tproxy-server
cat > /etc/tproxy-server/config.json <<EOF2
{"public_hostname":"$DOMAIN","listen":"127.0.0.1:8080","admin_listen":"127.0.0.1:8081","public_dir":"/srv/tproxy-site","profiles_file":"/run/credentials/tproxy-server.service/profiles.json"}
EOF2
cat > /etc/tproxy-server/profiles.json <<EOF2
{"profiles":[{"name":"default","secret":"$SECRET","backend":"127.0.0.1:2398"}]}
EOF2
chown root:tproxy /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
chmod 0640 /etc/tproxy-server/config.json; chmod 0400 /etc/tproxy-server/profiles.json
backend_secret="${SECRET#dd}"
install -d -o root -g mtproxy -m 0750 /etc/mtproxy
cat > /etc/mtproxy/mtproxy.env <<EOF2
MTPROXY_SECRET=$backend_secret
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
EOF2
chown root:mtproxy /etc/mtproxy/mtproxy.env; chmod 0640 /etc/mtproxy/mtproxy.env

install -m 0644 "$REPO_DIR/deploy/tproxy-server.service" /etc/systemd/system/tproxy-server.service
install -m 0644 "$REPO_DIR/deploy/mtproxy.service" /etc/systemd/system/mtproxy.service
install -m 0644 "$REPO_DIR/deploy/tproxy-firewall.service" /etc/systemd/system/tproxy-firewall.service
install -m 0644 "$REPO_DIR/deploy/refresh-mtproxy-config.service" /etc/systemd/system/refresh-mtproxy-config.service
install -m 0644 "$REPO_DIR/deploy/refresh-mtproxy-config.timer" /etc/systemd/system/refresh-mtproxy-config.timer
install -m 0755 "$REPO_DIR/deploy/refresh-mtproxy-config.sh" /usr/local/sbin/refresh-mtproxy-config
install -m 0644 "$REPO_DIR/deploy/firewall.nft" /etc/tproxy-server/firewall.nft

caddy_version="2.11.4"
caddy_sha512="8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9"
CADDY_ARCHIVE="$(mktemp /tmp/caddy.XXXXXX.tar.gz)"; CADDY_DIR="$(mktemp -d /tmp/caddy.XXXXXX)"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$CADDY_ARCHIVE" "https://github.com/caddyserver/caddy/releases/download/v${caddy_version}/caddy_${caddy_version}_linux_amd64.tar.gz"
[[ "$(sha512sum "$CADDY_ARCHIVE" | awk '{print $1}')" == "$caddy_sha512" ]] || die "Caddy checksum verification failed."
tar -C "$CADDY_DIR" -xzf "$CADDY_ARCHIVE"
install -m 0755 "$CADDY_DIR/caddy" /usr/local/bin/caddy
id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
install -d -o root -g caddy -m 0750 /etc/caddy
install -d -o caddy -g caddy -m 0750 /var/lib/caddy
install -m 0644 "$REPO_DIR/deploy/caddy.service" /etc/systemd/system/caddy.service

cat > /etc/caddy/Caddyfile <<'EOF2'
{
    admin off
    auto_https on
    servers {
        protocols h1 h2
    }
}
{$TPROXY_HOSTNAME} {
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
EOF2
install -d -m 0755 /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/tproxy.conf <<EOF2
[Service]
Environment=TPROXY_HOSTNAME=$DOMAIN
Environment=TPROXY_SITE_ROOT=/srv/tproxy-site
Environment=ACME_EMAIL=$EMAIL
ReadWritePaths=/etc/caddy
EOF2

fix_mtproxy_permissions(){
  chmod 0755 /opt/MTProxy /opt/MTProxy/objs /opt/MTProxy/objs/bin /opt/MTProxy/objs/bin/mtproto-proxy
  runuser -u mtproxy -- test -x /opt/MTProxy/objs/bin/mtproto-proxy || die "mtproxy user cannot execute mtproto-proxy."
}
fix_mtproxy_permissions
runuser -u tproxy -- test -r "$SITE_TARGET/index.html" || die "tproxy cannot read site."
/usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json -profiles-file /etc/tproxy-server/profiles.json -check
TPROXY_HOSTNAME="$DOMAIN" TPROXY_SITE_ROOT=/srv/tproxy-site ACME_EMAIL="$EMAIL" /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw status | grep -Eq '^80(/tcp)?[[:space:]]+ALLOW|^80/tcp[[:space:]]+ALLOW' || die "UFW is active and port 80/tcp is not allowed. Open 80/tcp first."
  ufw status | grep -Eq '^443(/tcp)?[[:space:]]+ALLOW|^443/tcp[[:space:]]+ALLOW' || die "UFW is active and port 443/tcp is not allowed. Open 443/tcp first."
fi

systemctl daemon-reload
systemctl enable --now tproxy-firewall.service
fix_mtproxy_permissions
systemctl enable --now mtproxy.service
for _ in {1..30}; do systemctl is-active --quiet mtproxy && port_listener 2398 && break; sleep 1; done
systemctl is-active --quiet mtproxy || die "MTProxy failed to start."

systemctl enable --now tproxy-server.service
for _ in {1..30}; do curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1 && break; sleep 1; done
curl -fsS --max-time 2 http://127.0.0.1:8081/healthz >/dev/null || die "tproxy-server health check failed."

systemctl enable --now refresh-mtproxy-config.timer
systemctl enable --now caddy.service

for _ in {1..90}; do curl -fsSI --max-time 5 "https://$DOMAIN/" >/dev/null 2>&1 && break; sleep 2; done
curl -fsSI --max-time 5 "https://$DOMAIN/" >/dev/null || { journalctl -u caddy -n 60 --no-pager || true; die "HTTPS did not become ready. Check DNS, firewall and ACME."; }

for unit in mtproxy tproxy-server caddy tproxy-firewall; do systemctl is-active --quiet "$unit" || die "$unit is not active."; done
systemctl is-enabled --quiet mtproxy tproxy-server caddy tproxy-firewall || die "A required service is not enabled."
systemctl is-enabled --quiet refresh-mtproxy-config.timer || die "Refresh timer is not enabled."
for p in 2398 8080 8081 80 443; do port_listener "$p" || die "Expected port $p is not listening."; done

TELEGRAM_SECRET="${SECRET#dd}"
echo
printf '%s\n' '============================================================' 'TELEGRAM WEB PROXY IS READY' '============================================================'
printf 'Domain: https://%s/\n' "$DOMAIN"
printf 'Secret: %s\n' "$SECRET"
printf 'Telegram Web Proxy: https://t.me/webproxy?server=%s&secret=%s\n' "$DOMAIN" "$TELEGRAM_SECRET"
echo 'Status: HTTPS OK / MTProxy ACTIVE / Relay READY / Firewall ACTIVE'
echo 'IMPORTANT: keep the secret private.'
