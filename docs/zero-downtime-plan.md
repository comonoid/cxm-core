# Бесшовная перезагрузка версии (zero-downtime reload) — дизайн и реализация

> Статус: РАЗРАБОТАНО И ПРОВЕРЕНО ЛОКАЛЬНО 2026-07-12 (живой reload под нагрузкой:
> 200 запросов во время свопа, 0 ошибок, туда и обратно). Прод-механика (blue-green
> systemd) написана, ждёт хоста. Запрос пользователя: «запретить на старом сервере
> новые записи, перенаправить на новый, дождаться обработки, убить старый».

## Ключевое решение: НЕ разделять чтения/записи — переключать ВЕСЬ трафик атомарно

Интуиция «запретить записи на старом» упрощается благодаря нашей архитектуре:
- **сервер stateless**: каждый HTTP-запрос = ровно одна PG-транзакция (runCxmTx over
  connectPerTxn), между запросами в процессе нет состояния; сессии — JWT (без стора);
- значит «дождаться обработки записей» = дождаться завершения in-flight HTTP-запросов
  (секунды), никаких очередей внутри процесса;
- обе версии могут КОРРЕКТНО писать в PG одновременно (транзакции сериализует Postgres),
  если схема совместима (см. «Миграции»). Разделение read/write добавило бы нюансов
  (классификация запросов, sticky-маршрутизация) без выгоды.

Итоговая схема (blue-green):
```
1. новый бинарь стартует ВТОРЫМ процессом (свой сокет/порт); его boot гонит миграции
2. health-гейт нового (+опц. смоук)
3. АТОМАРНЫЙ своп точки входа → новые запросы идут новому
4. старому SIGTERM → warp перестаёт принимать, дорабатывает in-flight (graceful, 30с) → exit
5. (откат: своп назад, пока старый жив — окно между 3 и 4 можно растянуть на проверку)
```

## Нюансы и их закрытие (по одному на строку кода)

| Нюанс | Решение | Где |
|---|---|---|
| Обрыв in-flight по SIGTERM | Warp graceful: setInstallShutdownHandler(TERM/INT → closeSocket) + setGracefulShutdownTimeout 30с — процесс сам выходит после дренажа | agdelte `hs/Agdelte/Http.hs` (serveHost/serveUnix/serveWithWs) |
| Атомарность переключения | прод: nginx `proxy_pass http://unix:.../active.sock` — СИМЛИНК, connect() резолвит путь на каждое соединение, `ln -sfn` атомарен; локально: прокси читает цель из файла на КАЖДЫЙ запрос, swap = mv файла | `deploy/nginx-psych.conf.tmpl`, `reload-site.sh`; `site-psych/dev/serve.mjs` (CXM_API_FILE), `host-local.sh reload` |
| Двойные ПИСЬМА в overlap (два воркера) | claim АТОМАРЕН: `claimOutboxV` = lockRoot (FOR UPDATE) + попытка учтена ПРИ claim'е (lastAttempt=now ⇒ у второго строка не due, backoff-щит); успех → markSent, провал — ничего (попытка уже посчитана) | ядро `Cxm.CommandsV.claimOutboxV`, сервер `deliverOne` |
| Двойные напоминания/bus в overlap | ЛИДЕР-ГЕЙТ тика: `tryLockKey nsWorker` (новый verb `rTryLockKey` = pg_try_advisory_xact_lock; парс через `SELECT 1 AS id WHERE …` — без нового декодера); remind+bus+выборка в ОДНОЙ транзакции под локом, не-лидер скипает тик | store-verb `Cxm.Store.Verbs` + `Pg`/`VerbsTest`; сервер `workerTick` |
| Миграции: старый бинарь на новой схеме | дисциплина УЖЕ Tier-1: хвостовые nullable-колонки, tolerant-декод; старый INSERT без новой колонки → NULL → ок. Опасное (DROP/RENAME/NOT NULL) — только expand→deploy→contract (contract отдельным релизом, когда старой версии нет). Ledger (schema_migrations) идемпотентен — повторный boot нового безвреден | конвенция + `Cxm.Store.Registry` (watch-refl) |
| Старые JS-бандлы во вкладках клиентов | contract-version в /health + сверка сайтом (красный баннер дрейфа) УЖЕ есть; правило аддитивности API соблюдаем | CxmUI.Contract.expectedContract |
| Вебхуки ЮKassa в окно свопа | редоставка идемпотентна (claim по extId, «granted:false» 200) — провайдер доретраит в любой из серверов | PsychCxm.Server.webhookTx |
| PG-пул | пула нет (connectPerTxn) — дренировать нечего; pgbouncer/v2 не меняет схему (пул вне процесса) | — |
| media-host/статика | отдельные процессы, версия сервера их не трогает; их own reload — тем же приёмом (нечасто нужен) | — |
| Зависший дренаж | graceful timeout 30с в warp + systemd TimeoutStopSec (юнит) / kill -9 в host-local через 35с | юниты, host-local.sh |

## Механика

**Локально** (`psych-platform/deploy/local/host-local.sh reload`): пара портов
API_PORT/API_PORT_ALT (8138/8139); активный — в файле `$STATE/api-target`, статик-прокси
читает его на каждый запрос. reload: старт нового на неактивном порту → health →
mv api-target → SIGTERM старому → ожидание выхода (35с, потом kill -9).
ПРОВЕРЕНО: 200 health-запросов через прокси во время свопа — 0 не-200; обратный
reload симметричен.

**Прод** (`psych-platform/deploy/reload-site.sh <slug>`): юниты
`cxm-server-pg-{blue,green}@<slug>` (сокеты `/run/sites/<slug>/{blue,green}.sock`),
nginx проксирует на симлинк `active.sock`. reload: старт неактивного цвета →
health через `curl --unix-socket` → `ln -sfn` → `systemctl stop` старого цвета
(SIGTERM → graceful). Откат = повторный запуск скрипта. На реальном хосте НЕ гонялся —
первый прогон по шагам.

## Чего сознательно НЕТ

- **Read-write разделения** — см. выше: атомарный своп всего трафика проще и достаточен.
- **Session-draining sticky-логики** — сессий нет (JWT).
- **Оркестратора** — один скрипт на инстанс; флот перезагружается пер-слагово
  (канареечно: обновил один сайт, посмотрел, остальные).
