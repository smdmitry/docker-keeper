# docker-keeper

Один контейнер, который следит за остальными контейнерами на хосте через `/var/run/docker.sock`:

- **autoheal**: перезапускает запущенные контейнеры в статусе `unhealthy`. Заменяет `willfarrell/autoheal` и использует ту же метку `autoheal=true`.
- **autostart**: запускает контейнеры, которые не смогли стартовать. Например, при загрузке хоста NAS был недоступен и cifs/nfs volume не смонтировался, или после перезапуска через autoheal монтирование упало. Docker сам такие старты не повторяет, даже с `restart: unless-stopped`. Контейнеры, остановленные вручную (`docker stop`, `docker compose stop`), не трогаются: keeper запускает только те, у которых заполнен `State.Error`, то есть последний запуск завершился ошибкой.
- **autoremove**: удаляет одноразовые контейнеры с меткой `keeper.autoremove=true` (init-скрипты и т. п.), если они завершились с кодом 0 больше `KEEPER_AUTOREMOVE_DELAY` секунд назад. Упавшие остаются, чтобы можно было посмотреть логи.
- **cron**: выполняет задачи по расписанию, которое задаётся метками на самих контейнерах: перезапустить, запустить, остановить или выполнить команду внутри.

Основан на образе `docker:cli`: shell-скрипты и `crond` из busybox, без зависимостей.

## Подключение

Образ собирается прямо из GitHub:

```yaml
services:
  docker-keeper:
    build: https://github.com/smdmitry/docker-keeper.git#main
    image: docker-keeper
    container_name: docker-keeper
    restart: unless-stopped
    network_mode: none
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      TZ: Europe/Moscow
```

Чтобы подтянуть свежий код: `docker compose build --no-cache docker-keeper && docker compose up -d docker-keeper`.

## Настройки (environment)

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `KEEPER_LABEL` | `autoheal` | autoheal и autostart обрабатывают контейнеры с меткой `<KEEPER_LABEL>=true`; `all` — все контейнеры |
| `KEEPER_INTERVAL` | `30` | секунд между проверками (и между пересборками crontab из меток) |
| `KEEPER_START_PERIOD` | `60` | секунд после старта keeper до первых autoheal/autostart, чтобы контейнеры успели подняться после загрузки хоста |
| `KEEPER_STOP_TIMEOUT` | `30` | `docker restart -t` / `docker stop -t`; для autoheal можно переопределить меткой `autoheal.stop.timeout` на контейнере |
| `KEEPER_CMD_TIMEOUT` | `180` | предел ожидания одного `docker start` или `restart` сверх времени остановки (зависший mount не блокирует остальных) |
| `KEEPER_AUTOHEAL` | `true` | включить autoheal |
| `KEEPER_AUTOSTART` | `true` | включить autostart |
| `KEEPER_CRON` | `true` | включить cron |
| `KEEPER_AUTOREMOVE` | `true` | включить autoremove |
| `KEEPER_AUTOREMOVE_DELAY` | `300` | секунд после успешного завершения до удаления контейнера |
| `TZ` | UTC | часовой пояс для расписаний cron |

## Метки контейнеров

### autoheal и autostart

```yaml
    labels:
      autoheal: "true"
      autoheal.stop.timeout: "60"   # необязательно
    healthcheck:                    # нужен для autoheal; для autostart не нужен
      test: ["CMD-SHELL", "curl -fsS http://localhost:8080/health && test -d /data"]
      interval: 30s
      timeout: 15s
      retries: 3
      start_period: 90s
```

Пример с NAS: volume cifs/nfs и healthcheck, который проверяет, что шара не пустая. Если NAS пропадёт, контейнер станет unhealthy, autoheal его перезапустит, монтирование при старте упадёт, и autostart будет пробовать запускать контейнер каждые `KEEPER_INTERVAL` секунд, пока NAS не вернётся. Без смонтированной шары контейнер не работает.

### autoremove

```yaml
  frigate-faces-init:
    restart: "no"
    labels:
      keeper.autoremove: "true"

  frigate:
    depends_on:
      frigate-faces-init:
        condition: service_completed_successfully
```

Задержка `KEEPER_AUTOREMOVE_DELAY` нужна, чтобы `docker compose up` успел дождаться завершения init-контейнера и запустить зависимые. При следующем `docker compose up` удалённый контейнер создаётся и выполняется заново, поэтому скрипт должен спокойно переносить повторный запуск. Не ставь эту метку на контейнеры, которые перезапускаются по cron (`keeper.cron.*`): после удаления перезапускать будет нечего.

### cron

Метки `keeper.cron.<job>.*`, где `<job>` — любое имя из `A-Za-z0-9_-`. На одном контейнере может быть несколько задач. Метка `autoheal` для cron не нужна. Задачи работают и для остановленных контейнеров.

| Метка | Значение |
|---|---|
| `keeper.cron.<job>.schedule` | расписание из 5 полей cron (`*/15 * * * *`) — обязательно |
| `keeper.cron.<job>.action` | `restart` (по умолчанию), `start` (если не запущен), `stop`, `exec` |
| `keeper.cron.<job>.command` | для `exec`: команда, выполняется через `sh -c` внутри контейнера |
| `keeper.cron.<job>.user` | для `exec`: пользователь (`docker exec -u`), по умолчанию пользователь контейнера |

```yaml
  yota-4g-init:
    restart: "no"
    labels:
      # одноразовый скрипт: перезапускать каждые 15 минут
      keeper.cron.rerun.schedule: "*/15 * * * *"

  nextcloud:
    labels:
      keeper.cron.bg.schedule: "*/5 * * * *"
      keeper.cron.bg.action: exec
      keeper.cron.bg.user: www-data
      keeper.cron.bg.command: php -f /var/www/html/cron.php
```

Метки читаются заново каждые `KEEPER_INTERVAL` секунд. После `docker compose up -d` с новыми метками перезапускать keeper не нужно. Что выполняется и чем закончилось, видно в `docker logs docker-keeper`.

## Безопасность

У keeper полный доступ к Docker на хосте через сокет. Ему достаточно `network_mode: none`.
