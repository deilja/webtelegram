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

## Рекомендуемый способ установки — универсальный

Для нового VPS и рабочего сервера с уже установленным Caddy используйте один установщик:

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy-universal.sh -o /root/install-webproxy-universal.sh
chmod 700 /root/install-webproxy-universal.sh
/root/install-webproxy-universal.sh
```

Установщик автоматически определяет состояние сервера:

```text
Caddy не установлен
      ↓
install-webproxy.sh
      ↓
устанавливает Caddy + Web Proxy
```

или:

```text
Caddy уже работает
      ↓
install-webproxy-existing-caddy.sh
      ↓
добавляет Web Proxy без замены существующих сайтов
```

### nginx

Если nginx уже работает, универсальный установщик **останавливается и ничего не изменяет**. Это сделано специально, чтобы не сломать production-сайты.

---

## Ручные варианты

### Чистый VPS без Caddy

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy.sh -o /root/install-webproxy.sh
chmod 700 /root/install-webproxy.sh
/root/install-webproxy.sh
```

Этот режим устанавливает Caddy самостоятельно.

### Существующий Caddy

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy-existing-caddy.sh -o /root/install-webproxy-existing-caddy.sh
chmod 700 /root/install-webproxy-existing-caddy.sh
/root/install-webproxy-existing-caddy.sh
```

Перед изменением Caddy создаётся backup в `/root/webproxy-backups/`.

Основной Caddyfile не заменяется целиком: добавляется отдельный fragment для Web Proxy и выполняется `caddy validate` перед reload.

---

## Что проверяет установка

1. root-доступ;
2. Ubuntu 24.04;
3. архитектура x86_64;
4. DNS A;
5. DNS AAAA, если он существует;
6. соответствие DNS публичному адресу VPS;
7. занятость backend-портов;
8. состояние Caddy/nginx;
9. UFW;
10. фиксированный commit `tproxy-server`.

Установщик не забирает 80/443 у уже работающего веб-сервера.

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

Backend-порты `2398`, `8080` и `8081` должны оставаться доступными только локально.

---

## После установки

```text
============================================================
             TELEGRAM WEB PROXY IS READY
============================================================

Domain:
  https://proxy.example.com/

Secret:
  ******************************

Telegram Web Proxy:
  https://t.me/webproxy?server=proxy.example.com&secret=************************

Status:
  HTTPS          OK
  MTProxy        ACTIVE
  Relay          READY
  Firewall       ACTIVE
============================================================
```

**Secret — чувствительные данные. Не публикуйте его и не помещайте в публичные issue/logs.**

---

## Проверка после установки

```bash
systemctl is-active mtproxy
systemctl is-active tproxy-server
systemctl is-active caddy
ss -lntp | grep -E ':(80|443|2398|8080|8081)\b'
```

Проверка relay:

```bash
curl -fsS http://127.0.0.1:8081/readyz
```

Проверка HTTPS:

```bash
curl -fsSI https://proxy.example.com/
```

---

## Существующий Caddy

Существующие сайты не должны быть перезаписаны.

Перед интеграцией создаётся backup:

```text
/root/webproxy-backups/<timestamp>/
```

В случае ошибки reload Caddy installer пытается восстановить исходный Caddyfile.

---

## Если порт 80 или 443 занят

```bash
ss -lntp | grep -E ':(80|443)\b'
```

Для чистой установки занятые 80/443 являются конфликтом. Не останавливайте production-сервис вслепую.

---

## UFW

Если UFW активен, должны быть разрешены:

```bash
ufw allow 80/tcp
ufw allow 443/tcp
```

Не открывайте наружу `2398`, `8080` или `8081`.

---

## HTML-заглушка

```text
/srv/tproxy-site/index.html
```

После изменения страницы перезапуск Caddy обычно не требуется.

---

## Удаление

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/uninstall-webproxy.sh -o /tmp/uninstall-webproxy.sh
chmod 700 /tmp/uninstall-webproxy.sh
/tmp/uninstall-webproxy.sh
```

На рабочем сервере перед удалением проверьте, не используются ли Caddy или его конфигурация другими сайтами.

---

## Безопасность

- только Ubuntu 24.04 x86_64;
- root-проверка;
- DNS-проверки;
- pinned `tproxy-server` commit;
- SHA-512 проверка Caddy;
- отдельные systemd users;
- systemd hardening;
- секреты с ограниченными правами;
- backend только localhost;
- backup существующего Caddy;
- `caddy validate` перед reload;
- nginx автоматически не изменяется.

---

## CI

GitHub Actions выполняет:

- `bash -n`;
- ShellCheck;
- статические security-проверки.

Перед production-установкой проверяйте последний успешный workflow.

---

## Репозиторий

[deilja/webtelegram](https://github.com/deilja/webtelegram)
