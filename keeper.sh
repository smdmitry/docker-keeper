#!/bin/sh
# docker-keeper: следит за контейнерами через /var/run/docker.sock.
#   autoheal  — перезапускает запущенные контейнеры в статусе unhealthy;
#   autostart — запускает контейнеры, которые не смогли стартовать (State.Error не пустой:
#               например, cifs/nfs volume не смонтировался, потому что NAS недоступен).
#               Остановленные вручную (docker stop / compose stop) не трогает: у них State.Error пустой;
#   cron      — выполняет задачи из меток keeper.cron.<job>.* (restart/start/stop/exec по расписанию);
#   autoremove — удаляет одноразовые контейнеры с меткой keeper.autoremove=true, успешно
#               завершившиеся (код 0) не меньше KEEPER_AUTOREMOVE_DELAY секунд назад.
# Подробности и метки — в README.md.
set -u

KEEPER_LABEL="${KEEPER_LABEL:-autoheal}"            # метка <KEEPER_LABEL>=true; all — все контейнеры
KEEPER_INTERVAL="${KEEPER_INTERVAL:-30}"            # секунд между проверками autoheal/autostart/cron-меток
KEEPER_START_PERIOD="${KEEPER_START_PERIOD:-60}"    # секунд после старта keeper до первых autoheal/autostart
KEEPER_STOP_TIMEOUT="${KEEPER_STOP_TIMEOUT:-30}"    # docker restart -t, если у контейнера нет метки autoheal.stop.timeout
KEEPER_CMD_TIMEOUT="${KEEPER_CMD_TIMEOUT:-180}"     # предел для одного docker start/restart (зависший mount)
KEEPER_AUTOHEAL="${KEEPER_AUTOHEAL:-true}"
KEEPER_AUTOSTART="${KEEPER_AUTOSTART:-true}"
KEEPER_CRON="${KEEPER_CRON:-true}"
KEEPER_AUTOREMOVE="${KEEPER_AUTOREMOVE:-true}"
KEEPER_AUTOREMOVE_DELAY="${KEEPER_AUTOREMOVE_DELAY:-300}"  # секунд после завершения до удаления
export KEEPER_STOP_TIMEOUT KEEPER_CMD_TIMEOUT

CRON_DIR=/var/spool/cron/crontabs
# Лог задач cron: crond отдаёт их вывод в /dev/null, поэтому задачи пишут в FIFO,
# а cat, запущенный при старте, переносит его в stdout контейнера (docker logs).
JOB_LOG=/run/keeper-job.log

log() { echo "$(date '+%F %T') [keeper] $*"; }

# run <timeout> <docker args...>: выполняет docker-команду, ошибку пишет одной строкой
run() {
  t="$1"; shift
  out=$(timeout "$t" docker "$@" 2>&1 >/dev/null) && return 0
  log "  failed: $(printf '%s' "${out:-timeout}" | head -n1)"
  return 1
}

label_filter() {
  [ "$KEEPER_LABEL" = all ] || echo "--filter=label=${KEEPER_LABEL}=true"
}

name_of() { docker inspect -f '{{.Name}}' "$1" 2>/dev/null | sed 's|^/||'; }

stop_timeout_of() {
  t=$(docker inspect -f '{{index .Config.Labels "autoheal.stop.timeout"}}' "$1" 2>/dev/null)
  case "$t" in ''|*[!0-9]*) echo "$KEEPER_STOP_TIMEOUT" ;; *) echo "$t" ;; esac
}

autoheal() {
  for id in $(docker ps -q $(label_filter) --filter health=unhealthy); do
    name=$(name_of "$id")
    log "autoheal: $name is unhealthy, restarting"
    t=$(stop_timeout_of "$id")
    run $((t + KEEPER_CMD_TIMEOUT)) restart -t "$t" "$id"
  done
}

autostart() {
  for id in $(docker ps -aq $(label_filter) --filter status=exited --filter status=created); do
    err=$(docker inspect -f '{{.State.Error}}' "$id" 2>/dev/null)
    [ -n "$err" ] || continue
    name=$(name_of "$id")
    log "autostart: starting $name (last error: $err)"
    run "$KEEPER_CMD_TIMEOUT" start "$id"
  done
}

# Удаляет одноразовые контейнеры (keeper.autoremove=true), которые завершились с кодом 0.
# Задержка нужна, чтобы docker compose успел увидеть завершение (depends_on:
# service_completed_successfully). Упавшие контейнеры остаются, чтобы можно было посмотреть логи.
autoremove() {
  now=$(date +%s)
  for id in $(docker ps -aq --filter label=keeper.autoremove=true --filter status=exited); do
    info=$(docker inspect -f '{{.State.ExitCode}} {{.State.FinishedAt}}' "$id" 2>/dev/null) || continue
    [ "${info%% *}" = 0 ] || continue
    fin="${info#* }"; fin="${fin%Z}"; fin="${fin%%.*}"
    fin_s=$(date -u -D '%Y-%m-%dT%H:%M:%S' -d "$fin" +%s 2>/dev/null) || continue
    [ $((now - fin_s)) -ge "$KEEPER_AUTOREMOVE_DELAY" ] || continue
    log "autoremove: removing $(name_of "$id") (exited 0 at $fin UTC)"
    run 60 rm "$id"
  done
}

# Собирает crontab из меток keeper.cron.<job>.schedule всех контейнеров (и остановленных)
# и отдаёт его crond, если он изменился. Сама задача (keeper-job) читает остальные метки
# в момент запуска, поэтому в crontab попадают только имя контейнера и задачи.
sync_cron() {
  ids=$(docker ps -aq)
  new=$(
    [ -n "$ids" ] && docker inspect -f \
      '{{$n := .Name}}{{range $k, $v := .Config.Labels}}{{$n}}{{"\t"}}{{$k}}{{"\t"}}{{$v}}{{"\n"}}{{end}}' \
      $ids 2>/dev/null \
    | awk -F '\t' '
        $2 ~ /^keeper\.cron\.[A-Za-z0-9_-]+\.schedule$/ {
          name = substr($1, 2); job = $2
          sub(/^keeper\.cron\./, "", job); sub(/\.schedule$/, "", job)
          n = split($3, f, /[ \t]+/)
          if (n != 5) { print "# skip " name "/" job ": bad schedule \"" $3 "\""; next }
          print $3 " /usr/local/bin/keeper-job " name " " job " >>'"$JOB_LOG"' 2>&1"
        }' \
    | sort
  )
  old=$(cat "$CRON_DIR/root" 2>/dev/null)
  [ "$new" = "$old" ] && return
  printf '%s\n' "$new" > "$CRON_DIR/root"
  echo root >> "$CRON_DIR/cron.update"
  log "cron: jobs updated:"
  printf '%s\n' "${new:-(none)}" | sed 's/ >>.*//; s/^/    /'
}

trap 'log "stopping"; [ -n "${crond_pid:-}" ] && kill "$crond_pid" 2>/dev/null; exit 0' TERM INT

log "starting: label=${KEEPER_LABEL} interval=${KEEPER_INTERVAL}s autoheal=${KEEPER_AUTOHEAL} autostart=${KEEPER_AUTOSTART} cron=${KEEPER_CRON} autoremove=${KEEPER_AUTOREMOVE}"
docker version -f 'docker {{.Server.Version}}' || { log "no access to docker socket"; exit 1; }

crond_pid=
if [ "$KEEPER_CRON" = true ]; then
  mkdir -p "$CRON_DIR"
  rm -f "$JOB_LOG" && mkfifo "$JOB_LOG"
  exec 4<>"$JOB_LOG"   # держим FIFO открытым, чтобы cat не получил EOF между задачами
  cat "$JOB_LOG" &
  : > "$CRON_DIR/root"
  sync_cron
  crond -f -d 8 -c "$CRON_DIR" &
  crond_pid=$!
fi

started=$(date +%s)
while :; do
  [ "$KEEPER_CRON" = true ] && sync_cron
  if [ $(( $(date +%s) - started )) -ge "$KEEPER_START_PERIOD" ]; then
    [ "$KEEPER_AUTOHEAL" = true ] && autoheal
    [ "$KEEPER_AUTOSTART" = true ] && autostart
    [ "$KEEPER_AUTOREMOVE" = true ] && autoremove
  fi
  if [ -n "$crond_pid" ] && ! kill -0 "$crond_pid" 2>/dev/null; then
    log "crond died, exiting"
    exit 1
  fi
  sleep "$KEEPER_INTERVAL" & wait $!
done
