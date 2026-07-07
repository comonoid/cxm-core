# PG-only store — план и контракты (2026-07-05; вычищено 2026-07-07)

> **Статус: PG-стор РЕАЛИЗОВАН и живёт.** `cxm-server-pg` работает на живом PostgreSQL 17
> (register→login→кабинет→/v1, owner-изоляция, 35 миграций через ledger). WAL удалён. Схема
> прод-готова. Осталось — катовер (деплой, ops пользователя) + необязательный хвост.
> Ниже: durable-контракты (действуют всегда) → «Реализовано» (сжато; детали в коде/git/памяти) →
> «Осталось». Пошаговые логи миль­стоунов и 8 аудит-проходов убраны — их итог в коде и docstring'ах.

## Решение
Единственный прод-стор CXM — **Postgres**. Причина: community-сайт (мелкие сайты интегрируются в
один крупный) → все таблицы растут вширь + конкурентные писатели + поиск/ленты/бэкапы. WAL-memory-image
как прод отменён; **дуал-бэкенда в проде нет** («в совместимость не играем»). Memory-image остаётся
как **эталонный интерпретатор** (референс-семантика + тест-дубль, без durability).

## Принципы
- **Инварианты и команды — верифицированная Agda**, гоняющая PG-транзакцию (`abort` → `ROLLBACK`).
  НИКАКОГО рукописного PL/pgSQL — любой SQL эмитится из типизированного Agda-терма.
- **Схема — единственный источник SQL**: DDL / INSERT / UPSERT / DELETE / SELECT — интерпретаторы
  `Agdelte.Storage.Schema` (вектор declarative-storage.md).
- **EDSL + два интерпретатора**: нативный (чистый, эталон, тесты без БД) и PG (прод). Дифф-тест
  `native ≡ compiled` — сетка безопасности для каждого скомпилированного пути.
- **Мы — стандарт для PG** (не наоборот): компилятор эмитит conformant-SQL — пиновать COLLATE,
  NULLS FIRST/LAST, детерминированный ORDER BY (tiebreaker по pk); не полагаться на дефолты PG.
- **Удобство Agda-стороны первично** (уточнение 2026-07-06): ГЛАВНОЕ — удобство серверного
  Agda-программиста; ради него допустимо значительное усложнение транслятора (на практике не ждём —
  удобные формы ложатся в реляционные примитивы ~1:1). **Граница:** лямбды непрозрачны для транслятора
  (freer-продолжение — функция) → что исполняется В базе, говорится ДАННЫМИ (byIndex/byCol/query-терм).
  **РЕШЕНИЕ 2026-07-06: лямбды в EDSL ЗАПРЕЩАЕМ.** Реализация без потери нотации — **PHOAS-слой** (после
  катовера): лямбда = чистый биндер над непрозрачной Var → всё дерево команды = данные. Покупает: один
  SQL-батч/CTE на команду (чаттинес умирает классом), СТАТИЧЕСКУЮ проверку lock-дисциплины (write-set ⊆
  locked-roots на компиляции), генерируемое in-DB исполнение (запрет был на РУКОПИСНЫЙ PL/pgSQL). Freer-Tx
  остаётся семантическим ядром: PHOAS элаборируется в Tx (эталон бесплатно, SQL-батч дифф-тестится).
  **Алгебра:** строим как **selective/applicative над тем же Req** (applicative ⊂ selective ⊂ монада).
  Applicative-фрагмент виден до запуска → батч + статический lock-set; selective добавляет выбор между
  статически видимыми ветками (find-or-create); монада — ядро + escape-hatch. «Только-applicative без
  монады» ОТВЕРГНУТ (порт невыразим). Представление данных — **opaque по дефолту** (TEXT/JSONB, логика
  в Agda); нормализация в реляции + компиляция запроса — **выборочный рычаг для горячих путей**.

## Конкурентность: READ COMMITTED навсегда (решение пользователя)
SERIALIZABLE отвергнут стратегически (retry-штормы под contention). Дисциплина RC:
1. **`lockRoot`-вербол**: команда первым делом лочит агрегат-корни (`SELECT … FOR UPDATE`) в
   каноническом порядке (таблица, id) — дедлоки исключены упорядочением. Внутри агрегата
   check-then-write race-free; разные корни бегут конкурентно (домен агрегатный: tenant=owner, per-subject).
2. **Create-if-absent гонки**: row-lock невозможен → `pg_advisory_xact_lock(classid, objid)` +
   UNIQUE второй линией. `classid = номер use-case` (неймспейсы против междоменных коллизий);
   глобальный порядок: сперва advisory, затем row-локи. Advisory ТОЛЬКО для create-if-absent.
3. **DDL-констрейнты** (UNIQUE/FK/CHECK) — держат при любой изоляции, превращают ошибку дисциплины
   в error, не в порчу. (Сейчас: UNIQUE login/token живут; FK/CHECK отложены — см. «Осталось».)
4. **Нативный интерпретатор = чекер дисциплины**: put/del без залоченного корня → громкий abort →
   гонка = детерминированный красный тест.
5. Retry-петля — только exception-path (deadlock/transient), не steady-state.
6. Запросы (ленты, bucket D) не лочат ничего — снапшот стейтмента им достаточен.

## Скоуп-контракт соединений (решение пользователя, 2026-07-05)
- **Единица работы = транзакция на приколотом соединении**. Отдельный «пул транзакций» НЕ нужен —
  пул соединений + pinned checkout.
- **В пуле — только транзакционно-скоупнутое**: `pg_advisory_xact_lock` (НЕ сессионные),
  `SET LOCAL` (не `SET`), temp-таблицы `ON COMMIT DROP`, `RETURNING` вместо `currval`.
  Prepared statements жертвуем (parse ~мкс; припрёт → pgbouncer protocol-prepared / выделенные соединения).
- **Сессионное — только на выделенных соединениях вне пула**: LISTEN/NOTIFY (будущий апгрейд воркера).

## Драйвер: `TxRunner`-шов (v1 ЖИВЁТ; v2 — апгрейд пользователя)
Шов — `TxRunner` = единственная capability `withConn : ∀ {A} → (Conn → IO A) → IO A`. Интерпретатор
`Tx` зависит ТОЛЬКО от раннера + Conn-верболов, никогда от Pool/conninfo. Эволюция БЕЗ правок выше шва:
- **v1 `connectPerTxn` — РЕАЛИЗОВАН и в проде-сервере** (новое соединение на транзакцию, ~1-2мс;
  pgbouncer спереди делает быстрым БЕЗ кода). Замер чаттинеса: свободный член ~4.7 ms/атом = именно
  этот connect (снимается pgbouncer/v2, нулём изменений выше шва).
- **v2 `pooledRunner`** (свой пул) — задача пользователя; шов не меняется. **Мина:** возврат соединения
  только санированным (ROLLBACK/discard упавших в транзакции).

**FFI-контракт (Conn-центричный):** `Conn`/`connect`/`close`/`execConn`/`queryConn` (примитивы) →
`withConnRaw = bracket connect close` → `TxRunner`; долгоживущий `SessionConn` → LISTEN/prepared/temp.
Про соединения знают ТОЛЬКО интерпретатор+main+владельцы сессий; Tx-программы — никогда. Agda-половина
(`Storage.PgConn`) + реализация hpgsql — готовы, живой сервер на них крутится.
`awaitNotification` зарезервирован комментом (для будущего мульти-процесса; сейчас single-process nudge).

## Реализовано (сжато — детали в коде, git-истории и памяти)
- **Ф0 Schema→SQL** (`Storage.SQL` + SQLTest): DDL(+индексы)/INSERT/UPSERT(ON CONFLICT pk)/DELETE/SELECT
  (all/byNat/byStr/page, ORDER BY pk), read-половина `Storage.JsonRow` (JSON→Row по имени колонки). refl.
- **Ф1 `Tx` freer** (`Storage.Free` + FreeTest, `--safe`): тотально БЕЗ sized types (континуация — поле
  конструктора). Интерпретаторы: чистый (эталон+lock-чекер), PG (`Storage.FreeIO.runTxPg`: BEGIN→фолд→COMMIT).
- **Ф1b query-EDSL** (`Storage.Query` + QueryTest): single-table filter+COUNT, колонки под `T(hasNatCol)`-
  гардом. **Live-дифф `pg-query-diff` ALL GREEN 6/6** (native `runCount` ≡ PG `compileCount`).
- **Ф2 порт домена = 100%: 85 refl.** `Cxm.Store.Verbs` (Req/Ans GADT ×28 + эргослой get/require/byIx/
  byCol/scan/put/del/fresh/lockRoot/lockKey/`lockRoots`-канон-порядок + rootOf/altRoots/appendOnly/
  queueTable), `Cxm.CommandsV` (все ~71 команд), `Cxm.Store.Pg` (вербол→SQL, `runCxmTx`), `Cxm.Store.Tables`
  (проводка ×28 + мост-refl к реестру), `Cxm.Store.VerbsTest` (чистый хэндлер). Закрыто ≥5 реальных гонок
  оригинала (double-booking, dup-ingest, find-then-create, воркер↔addEdge дедлок).
- **PG-СЕРВЕР ЖИВ** (`server/CxmServerPg.agda`): boot = ledger-миграции (schema_migrations над cxmHistory)
  → seed (тенант+админ) → listen; каждый запрос = одна PG-транзакция. Полная кабинетная (~35 роутов) +
  `/v1` (гейт integration-token → тенант владельца) поверхность, RBAC (`can`/pathPerm/rolesOfLogin),
  соц-читалки (feed/thread/showcase), транспорты воркера (webhook+email+nudge), `rebuildInferenceV`
  (перестройка гипотез, owner-scoped). e2e-смоук зелёный (юникод/эмодзи насквозь, owner-изоляция).
- **WAL УДАЛЁН начисто** (движок IndexedMap/NatMap/WAL/Txn + команды Commands/Txn/Api/Worker/Store.{Interface,
  Codec,Wal,…}); стор PG-only; `check-layering.sh` переписан (драйвер/IO + guardedness только в Store.Pg);
  `pg-diff` ALL GREEN — семантика сохранена.
- **Миграции-EDSL** (`Storage.Migration` + MigrationTest): `MigStep` (up/down/чистая модель) + сторож
  `migrate cxmHistory [] ≡ cxmSchemas` (схема без миграции ⇒ не компилируется) + `checkMigrations`
  (wellformedness, refl-гейт, 6 негатив-refl) + rollback-раннер `pg-rollback` (all-or-nothing, live happy+refuse).
  Реестр `Cxm.Store.Registry` (28 таблиц → cxmSchemas/genesis/cxmHistory).
- **Схема прод-готова** (аудит живой схемы): хардненинг-индексы на всех `byCol`-путях —
  UNIQUE `user.login`/`integration_token.token` (глоб-уникальны по семантике), PLAIN
  external_id/role_assignment.subject/payment.ext_id/protocol.name; model-invisible шаги `mIndexU`/`mIndexP`
  (не трогают byIx). Дубль-регистрация → чистый 409 (`registerOwnerV` find-then-reject). Live-проверено.
- **Чаттинес замерена** (`pg-bench`): 13-39 round-trip/атом, 9-19 ms на loopback — приемлемо; два рычага
  (pgbouncer/v2 для connect, PHOAS для round-trips) — после катовера.
- **Аудит:** пройдено ~10 adversarial-проходов, ВСЕ находки закрыты; выведенные контракты записаны в
  docstring'и кода: `fresh`→немедленный put (E1, live-дифф id-нечувствителен), `byIx`=МНОЖЕСТВО без
  порядка (F1), последовательные lockRoot возрастают по (code,id) (E3), advisory-неймспейсы 1-5,
  `hashKey` ограничен int4 (advisory objid), append-only отвергает del, decode-fail=Invariant (асимметрия).

## Осталось
- **Катовер (ops пользователя):** деплой `cxm-server-pg` на прод-PG + верификация. Данных для миграции
  НЕТ (WAL мёртв) — стартует с чистого листа. **Наш предеплой-шаг (по сигналу):** заморозить `cxmHistory`
  в литерал (заменить `= genesis` копией истории) → включается migration-watch: далее изменение Wire без
  дописанного `MigStep` ломает компиляцию Registry. Не блокер до появления прод-данных. Деплой под
  **Debian 13 / Docker** — разведка в памяти ([[cxm-pg-deploy-groundwork]]): бинарь чист от libpq,
  собирать в Docker(debian:trixie+ghcup), образец `/home/n/sergey-site`.
- **Driver v2** (персистентный коннект/пул) — апгрейд пользователя; `TxRunner` готов, выше шва ничего не меняется.
- **PHOAS/selective-слой** (после катовера) — лямбда-свободные команды → SQL-батч/CTE + статический lock-set.
- **FK/CHECK-констрейнты** — вторая линия дисциплины, отложены осознанно (целостность каскадами,
  инварианты в типах команд). Эмиссия FK из `CFK` схемы — когда понадобится.
- **Транспорты P3** — telegram/SMS; crypto-shred для GDPR (дизайн-ёмко: per-subject ключ + удаление на erase).
- **cxm-ui** — заблокировано пользователем (frontend-слой, [[cxm-frontend-layering]]).

## Зарезервировано: вложенные транзакции (решение 2026-07-06)
Сейчас и надолго НЕ нужны, но возможность открыта конструкцией:
- PG: SAVEPOINT/ROLLBACK TO/RELEASE — обычные строки через execConn, **контракт PgConn не меняется**;
- язык: ОДИН конструктор `sub : Tx B → (E ⊎ B → Tx A) → Tx A` + по клаузе в интерпретаторах;
- **Тонкость:** PG не освобождает локи при ROLLBACK TO SAVEPOINT → нативный интерпретатор на откате
  восстанавливает СТЕЙТ, но СОХРАНЯЕТ локи (монотонность 2PL держится и с вложенностью).

## Реактивность (решения 2026-07-05)
- **LISTEN/NOTIFY НЕ строим** («всё проходит через нас»). Single-process: воркер будится in-process
  post-commit **nudge** (`Agdelte.FFI.Server.nudgeWorker`/`forkLoopNudged` — РЕАЛИЗОВАН, письмо
  верификации мгновенно вместо ожидания CXM_WORKER_SEC). Слот `awaitNotification` зарезервирован
  под будущий мульти-процесс (отделённый воркер, WS-push фанаут).

## Среда
stdlib v2.4-35, Agda 2.9.0. Scratch-PG для тестов: `cxm-core/scripts/pg-scratch.sh`
(юзерспейс initdb+pg_ctl, 127.0.0.1:55432). Сборка PG-бинарей — build-харнесс в `~/.agda/agdelte`
(`gen:cxm-server-pg`/`pg-diff`/`pg-bench`/`pg-rollback`/`pg-query-diff`).
