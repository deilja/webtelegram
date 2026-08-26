# Telegram Web Proxy — Ubuntu 24.04

Production-ready installer for Telegram Web Proxy on **Ubuntu 24.04 x86_64**.

Проект использует:

- MTProxy
- `tproxy-server`
- Caddy
- HTTPS / Let's Encrypt
- systemd
- nftables
- HTML-заглушку

Upstream `tproxy-server` фиксируется на проверенном commit, чтобы установка не зависела от случайных изменений `master`.

---

## Требования

- Ubuntu 24.04 x86_64
- root-доступ
- домен или поддомен
- DNS A-запись на IPv4 VPS
- TCP 80/443 должны быть доступны для нового публичного hostname

---

## Рекомендуемый способ для сервера с 3X-UI

Используйте безопасный установщик:

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy-3xui-safe.sh -o /root/install-webproxy-3xui-safe.sh
chmod 700 /root/install-webproxy-3xui-safe.sh
/root/install-webproxy-3xui-safe.sh
```

Он сначала определяет:

- 3X-UI / Xray;
- Caddy;
- nginx;
- владельца TCP 80/443.

### Если Xray использует 443

Установщик **останавливается без изменений системы**. Он не меняет Xray, 3X-UI, panel port или `/usr/local/x-ui/bin/config.json`, потому что Caddy и Xray не могут одновременно занимать один TCP 443.

После этого выбирается архитектура:

1. перенести Xray за reverse proxy;
2. использовать другой публичный порт;
3. вынести Web Proxy на отдельный VPS/IP.

### Если 443 свободен

Даже при установленном 3X-UI installer использует обычный hardened clean-install path. Xray и 3X-UI не изменяются.

### Если уже работает Caddy

Создаётся backup Caddyfile, после чего используется existing-Caddy installer. Существующие сайты не должны заменяться целиком.

### Если 443 занимает nginx

Автоматического изменения nginx нет. Установщик останавливается, чтобы не сломать production-конфигурацию.

---

## Универсальный способ

Для обычного VPS без необходимости специальной диагностики:

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy-universal.sh -o /root/install-webproxy-universal.sh
chmod 700 /root/install-webproxy-universal.sh
/root/install-webproxy-universal.sh
```

Универсальный установщик предназначен для чистого VPS и существующего Caddy. Для VPS с 3X-UI сначала рекомендуется `install-webproxy-3xui-safe.sh`.

---

## Ручные варианты

### Чистый VPS без Caddy

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy.sh -o /root/install-webproxy.sh
chmod 700 /root/install-webproxy.sh
/root/install-webproxy.sh
```

### Существующий Caddy

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy-existing-caddy.sh -o /root/install-webproxy-existing-caddy.sh
chmod 700 /root/install-webproxy-existing-caddy.sh
/root/install-webproxy-existing-caddy.sh
```

---

## Архитектура

```text
Internet
   |
   +-- TCP 443 --> Caddy
   |                 |
   |                 +--> 127.0.0.1:8080
   |                          |
   |                          v
   |                    tproxy-server
   |                          |
   |                          v
   |                    127.0.0.1:2398
   |                          |
   |                          v
   |                       MTProxy
   |
   +-- TCP 80 --> Caddy / ACME
```

Backend-порты не должны быть доступны из интернета.

---

## Проверка

```bash
systemctl is-active mtproxy
systemctl is-active tproxy-server
systemctl is-active caddy
ss -lntp | grep -E ':(80|443|2398|8080|8081)\b'
```

Для диагностики 3X-UI/Xray:

```bash
systemctl status x-ui --no-pager
ss -lntp | grep -E ':(80|443)\b'
```

---

## Безопасность

Установщики:

- работают только от root;
- ограничены Ubuntu 24.04 x86_64;
- проверяют DNS до установки;
- фиксируют upstream `tproxy-server` на commit;
- проверяют SHA-512 Caddy;
- используют отдельные systemd users;
- держат backend на localhost;
- не останавливают Xray/3X-UI автоматически;
- не заменяют `/usr/local/x-ui/bin/config.json`;
- останавливаются при опасном конфликте 80/443;
- создают backup перед интеграцией с существующим Caddy.

---

## CI

GitHub Actions проверяет shell-синтаксис, ShellCheck, security assertions и production-сценарии.

---

## Репозиторий

[deilja/webtelegram](https://github.com/deilja/webtelegram)
