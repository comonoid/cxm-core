#!/usr/bin/env bash
# pg-scratch — временный одноразовый Postgres для тестов (pg-diff и т.п.), NixOS-friendly:
# юзерспейс, без root/systemd/docker. Данные в /tmp — умирают с ребутом, и это фича.
#
#   scripts/pg-scratch.sh start   → поднимает PG на 127.0.0.1:55432 (trust), создаёт БД cxmtest,
#                                    печатает готовый CXM_PG
#   scripts/pg-scratch.sh stop    → останавливает и удаляет каталог
#   scripts/pg-scratch.sh status
#
# 127.0.0.1 (не unix-сокет): hpgsql — чистый Haskell, TCP; и не "localhost" —
# hpgsql не перебирает A/AAAA (грабля из docs/POSTGRES-SPIKE.md).
set -euo pipefail

DIR="${PG_SCRATCH_DIR:-/tmp/pg-scratch}"
PORT="${PG_SCRATCH_PORT:-55432}"
DB="${PG_SCRATCH_DB:-cxmtest}"
PGUSER="$(whoami)"

run() { nix-shell -p postgresql --run "$*"; }

case "${1:-}" in
  start)
    if [ -f "$DIR/data/postmaster.pid" ]; then
      echo "уже запущен: CXM_PG=\"host=127.0.0.1 port=$PORT dbname=$DB user=$PGUSER\""; exit 0
    fi
    mkdir -p "$DIR"
    run "initdb -D '$DIR/data' -U '$PGUSER' -A trust -E UTF8 >/dev/null"
    # -k: сокеты в наш каталог (дефолт /run/postgresql на NixOS недоступен без root)
    run "pg_ctl -D '$DIR/data' -l '$DIR/log' -o '-p $PORT -c listen_addresses=127.0.0.1 -k $DIR' start"
    sleep 1
    run "createdb -h 127.0.0.1 -p $PORT -U '$PGUSER' '$DB'" || true
    echo "готово: CXM_PG=\"host=127.0.0.1 port=$PORT dbname=$DB user=$PGUSER\""
    ;;
  stop)
    run "pg_ctl -D '$DIR/data' stop" || true
    rm -rf "$DIR"
    echo "остановлен и удалён ($DIR)"
    ;;
  status)
    run "pg_ctl -D '$DIR/data' status" || true
    ;;
  *)
    echo "usage: $0 start|stop|status"; exit 1
    ;;
esac
