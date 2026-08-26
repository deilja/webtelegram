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

### Вариант A — новый VPS

- Ubuntu 24.04 x86_64
- root-доступ
- домен или поддомен
- DNS A-запись на IPv4 VPS
- порты TCP 80 и 443 свободны

### Вариант B — рабочий сервер с существующим Caddy

Используйте отдельный установщик:

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy-existing-caddy.sh -o /root/install-webproxy-existing-caddy.sh
chmod 700 /root/install-webproxy-existing-caddy.sh
/root/install-webproxy-existing-caddy.sh
```

Он не заменяет основной Caddyfile и выполняет reload Caddy после добавления отдельной конфигурации. Перед изменениями создаётся backup.

> Если сервер использует nginx вместо Caddy, этот режим не применяется. Не заменяйте nginx автоматически: сначала добавьте отдельный reverse-proxy location вручную или используйте специальный nginx-интегратор.

---

## Быстрая установка на чистый VPS

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/install-webproxy.sh -o /root/install-webproxy.sh
chmod 700 /root/install-webproxy.sh
/root/install-webproxy.sh
```

Установщик запросит:

```text
Domain (example: proxy.example.com):
ACME email:
Generate a secure secret automatically? [Y/n]:
```

Секрет рекомендуется генерировать автоматически.

---

## Что проверяет установщик

Перед изменением системы выполняются проверки:

1. root-доступ;
2. Ubuntu 24.04;
3. архитектура x86_64;
4. DNS A;
5. DNS AAAA, если он существует;
6. соответствие DNS публичному адресу VPS;
7. занятость портов;
8. наличие Caddy/nginx;
9. UFW;
10. контрольная версия upstream `tproxy-server`.

Установщик не пытается забрать 80/443 у уже работающего веб-сервера.

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

## После установки

При успешной установке отображаются:

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

Ожидаемая модель:

- `80/tcp` — Caddy;
- `443/tcp` — Caddy;
- `2398/tcp` — только localhost;
- `8080/tcp` — только localhost;
- `8081/tcp` — только localhost.

Проверка локального relay:

```bash
curl -fsS http://127.0.0.1:8081/readyz
```

Проверка HTTPS:

```bash
curl -fsSI https://proxy.example.com/
```

---

## Существующий Caddy

Используйте:

```text
install-webproxy-existing-caddy.sh
```

Принцип:

```text
Существующий Caddy
        |
        +-- существующие сайты остаются без изменений
        |
        +-- новый host --> tproxy-server :8080
```

Перед изменением Caddy создаётся backup в:

```text
/root/webproxy-backups/
```

Основной Caddyfile не заменяется целиком.

---

## Если порт 80 или 443 занят

Проверить:

```bash
ss -lntp | grep -E ':(80|443)\b'
```

Для чистой установки это ожидаемая причина остановки. Не останавливайте работающий production-сервис вслепую.

---

## UFW

Если UFW активен, должны быть разрешены:

```bash
ufw allow 80/tcp
ufw allow 443/tcp
```

Не открывайте наружу backend-порты `2398`, `8080` и `8081`.

---

## HTML-заглушка

Основная страница:

```text
/srv/tproxy-site/index.html
```

После изменения файла перезапуск Caddy обычно не требуется.

Не меняйте владельца и права на произвольные значения: установщик использует отдельного системного пользователя для доступа к файлам.

---

## Удаление

```bash
curl -fsSL https://raw.githubusercontent.com/deilja/webtelegram/main/uninstall-webproxy.sh -o /tmp/uninstall-webproxy.sh
chmod 700 /tmp/uninstall-webproxy.sh
/tmp/uninstall-webproxy.sh
```

Перед удалением обязательно проверьте, не используется ли Caddy другими сайтами.

---

## Безопасность

Установщик:

- работает только от root;
- ограничен Ubuntu 24.04 x86_64;
- проверяет DNS до установки;
- фиксирует upstream `tproxy-server` на commit;
- проверяет SHA-512 архива Caddy;
- использует отдельные systemd users;
- применяет systemd hardening;
- хранит секреты с ограниченными правами;
- держит backend на localhost;
- не перезаписывает существующий nginx/Caddy в режиме чистой установки;
- сохраняет backup при интеграции с существующим Caddy.

Не запускайте непроверенные копии installer от сторонних лиц.

---

## CI

Для shell-кода проекта используется GitHub Actions с:

- `bash -n`;
- ShellCheck;
- статическими security-проверками.

Перед production-релизом проверяйте последний успешный workflow.

---

## Репозиторий

[deilja/webtelegram](https://github.com/deilja/webtelegram)
