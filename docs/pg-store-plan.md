# PG-only store — план и контракты (2026-07-05)

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
- **Удобство Agda-стороны первично** (уточнение пользователя 2026-07-06: ГЛАВНОЕ — удобство
  серверного Agda-программиста; ради него допустимо ЗНАЧИТЕЛЬНОЕ усложнение транслятора — на практике
  большого не ожидается, т.к. удобные формы ложатся в реляционные примитивы ~1:1). **Граница принципа:**
  лямбды непрозрачны для транслятора (freer-продолжение — функция) → что должно исполниться В базе,
  говорится ДАННЫМИ (byIndex/byCol/query-терм); наша работа — делать data-формы не хуже лямбд.
  Ф2-раскатка обязана включить: сахар per-таблица (getSubject/putIdentity), lockRoots-комбинатор
  (канонический порядок внутри), рекорды/Maybe/enum как есть. Сложность впитывает транслятор.
  **РЕШЕНИЕ 2026-07-06 (пользователь): лямбды в EDSL ЗАПРЕЩАЕМ** — «имеем полное право», и не только
  в общем виде. Реализация без потери нотации — **PHOAS-слой** (Ф2+, ПОСЛЕ раскатки на Tx): лямбда =
  чистый биндер над непрозрачной Var (только data-операции у аргумента) → всё дерево команды —
  данные. Покупает: один SQL-батч/CTE на команду (чаттинес умирает классом), СТАТИЧЕСКУЮ проверку
  lock-дисциплины (write-set ⊆ locked-roots при компиляции; потом — автовывод локов), генерируемое
  in-DB исполнение (запрет был на РУКОПИСНЫЙ PL/pgSQL; сгенерированный из инспектируемого терма =
  как наш SQL). Freer-Tx остаётся семантическим ядром: PHOAS элаборируется в Tx (эталон бесплатно,
  SQL-батч дифф-тестится против элаборации). Словарь комбинаторов — из фактических команд после
  порта Ф2. Query-слой лямбда-свободен уже сейчас.
  **Алгебраическое уточнение (обсуждение 2026-07-06):** PHOAS-слой строим как **selective/applicative
  функтор над тем же Req** (лестница: чистый applicative ⊂ selective ⊂ монада). Applicative-фрагмент =
  всё дерево видно до запуска (Haxl-класс) → один SQL-батч/CTE, СТАТИЧЕСКИЙ lock-set. Selective
  добавляет выбор между статически видимыми ветками (lock-set = объединение; SQL CASE/условные CTE) —
  покрывает find-or-create. Многие bind'ы — фальшивые зависимости: freshId→RETURNING/CTE-ссылка
  (=PHOAS Var), каскад→сет-вербол delWhere, гарды→гард-верболы (условие считает БАЗА; динамический
  ROLLBACK в applicative СОХРАНЯЕТСЯ — провал вербола валит батч; теряется только хост-ветвление
  формы). Монада — семантическое ядро + escape-hatch для истинно форма-динамических команд;
  «только-applicative без монады» ОТВЕРГНУТ (порт Ф2 невыразим, удар по удобству). Представление данных —
  **opaque по дефолту** (TEXT/JSONB, логика в Agda); нормализация в реляции + компиляция запроса —
  **выборочный рычаг только для горячих путей** (обратимо, семантика фиксирована эталоном).
  Рекурсивные типы при нормализации → self-FK + `WITH RECURSIVE` (не блоб+PL/SQL).

## Конкурентность: READ COMMITTED навсегда (решение пользователя)
SERIALIZABLE отвергнут стратегически (retry-штормы под contention; переучивать команды на явные
блокировки в проде = переделать пол-движка). Дисциплина RC:
1. **`lockRoot`-вербол в алгебре `Tx`**: команда первым делом лочит агрегат-корни (строка
   subject/tenant/account/resource, `SELECT … FOR UPDATE`) в каноническом порядке (таблица, id) —
   дедлоки исключены упорядочением. Внутри агрегата check-then-write race-free; разные корни бегут
   конкурентно. Домен естественно агрегатный (tenant=owner, per-subject команды).
2. **Create-if-absent гонки** (resolveOrCreateSubject/bindIdentity): row-lock невозможен (строки нет) →
   `pg_advisory_xact_lock(classid, objid)` + UNIQUE-констрейнт второй линией. Оговорки (2026-07-05):
   advisory держит только соглашающихся (у нас ок: все записи через один Tx-интерпретатор + чекер);
   **classid = номер use-case** (неймспейсы, hash в objid) — против междоменных коллизий; **глобальный
   порядок локов покрывает ОБА вида**: сперва advisory (по classid,objid), затем row-локи (по таблица,id) —
   иначе advisory↔row дедлок. Advisory ТОЛЬКО для create-if-absent; существующее — FOR UPDATE.
3. **DDL-констрейнты** (UNIQUE/FK/CHECK; FK эмитится из `CFK` схемы) — держат при любой изоляции,
   превращают ошибку дисциплины в error, не в порчу.
4. **Нативный интерпретатор = чекер дисциплины**: put/del без залоченного корня → громкий abort →
   гонка = детерминированный красный тест (доказано в FreeTest).
5. Retry-петля — только exception-path (deadlock/transient), не steady-state.
6. Запросы (ленты, bucket D) не лочат ничего — снапшот стейтмента им достаточен.

## Скоуп-контракт соединений (решение пользователя, 2026-07-05)
- **Единица работы = транзакция на приколотом соединении**: `withTransaction : Pool → (Conn → IO A) → IO A`.
  Отдельный «пул транзакций» НЕ нужен — пул соединений + pinned checkout.
- **В пуле — только транзакционно-скоупнутое**: `pg_advisory_xact_lock` (НЕ сессионные `pg_advisory_lock`),
  `SET LOCAL` (не `SET`), temp-таблицы `ON COMMIT DROP`, `RETURNING` вместо `currval`, обычные курсоры
  (WITH HOLD не используем). Prepared statements — жертвуем (parse-cost ~мкс; если припрёт: pgbouncer
  ≥1.21 protocol-prepared в txn-режиме или выделенные соединения под сверхгорячее).
- **Сессионное — только на выделенных соединениях вне пула**: LISTEN/NOTIFY (будущий апгрейд
  outbox-воркера вместо поллинга).

## Драйвер (пользователь смотрит в отдельной сессии)
`Agdelte.Storage.Postgres` сейчас — pool-level `execSql/queryJson` (каждый вызов может взять другое
соединение) → **многостейтментные транзакции невозможны**.

**Абстракция транзакции (решение 2026-07-05):** шов — `TxRunner` = единственная capability
`withConn : ∀ {A} → (Conn → IO A) → IO A`. Интерпретатор `Tx` зависит ТОЛЬКО от раннера +
Conn-уровневых верболов, никогда от Pool/conninfo. Runner владеет получением соединения;
интерпретатор — транзакционной семантикой (BEGIN/COMMIT/ROLLBACK, SET LOCAL, retry) — одинаковой
для всех раннеров. Эволюция без правок выше шва:
  v1 `connectPerTxn conninfo` (новое соединение на транзакцию, ~1-2мс — ок для старта;
     pgbouncer спереди делает v1 быстрым БЕЗ кода) → v2 `pooledRunner` (свой внутренний пул).

**Минимальный FFI-контракт (Haskell-сторона) — Conn-центричный с первого дня (решение 2026-07-05,
чтобы сессионный мир добавлялся аддитивно, без слома совместимости):** примитивы
  `Conn : Set` (opaque) · `connect : String → IO Conn` · `close : Conn → IO ⊤` ·
  `execConn : Conn → String → IO Nat` · `queryConn : Conn → String → IO String` (JSON);
производные: `withConnRaw = bracket connect close` (exception-safety ТОЛЬКО в Haskell-bracket, Agda
исключения не ловит) → `TxRunner`; долгоживущий `SessionConn` (connect и держать + reconnect) →
сессионный мир (LISTEN/NOTIFY, session-prepared, cross-txn temp). Про соединения знают ТОЛЬКО
интерпретатор, main и 1-2 владельца сессий; Tx-программы — никогда (совместимость by construction).
BEGIN/COMMIT/FOR UPDATE — обычные строки. **Проверить в драйверной сессии: поддержка async
notifications в hpgsql** (нужен `awaitNotification : Conn → IO String` для LISTEN; нет — poll/патч).

**Agda-половина контракта ГОТОВА: `agdelte-store/Agdelte/Storage/PgConn.agda`** (typechecks) —
постулаты 4 примитивов + `withConnRaw` + record `TxRunner` + `connectPerTxn` (v1). Драйверная сессия
дописывает Haskell-функции и `COMPILE GHC`-прагмы к ЭТИМ сигнатурам. LISTEN-решение (2026-07-05):
ближайшего применения НЕТ (single-process: outbox-воркер будится in-process nudge'ем после коммита —
кстати, это отдельная быстрая улучшайка: письмо верификации сейчас ждёт до CXM_WORKER_SEC=30с;
остальное — поллинг); слот `awaitNotification` зарезервирован комментом в PgConn под будущий
мульти-процесс (отделённый воркер, WS-push фанаут по репликам).
**Мина v2-пула:** возврат соединения только санированным (ROLLBACK/discard, если блок упал в
транзакции) — иначе следующий клиент получает грязный коннект. Опционально-потом: `$1`-параметры,
LISTEN-колбэк на выделенном соединении.

## ★★★ WAVE-2 ЖИВА (2026-07-07): полная кабинетная + /v1 поверхность на живом PG
- **РЕШЕНИЕ пользователя: WAL НЕ поддерживаем** — cxm-server-pg = единственный сервер, старый
  WAL-путь (Commands/Txn/Wal/Api) идёт под снос после катовера (ретайр-шаг в плане).
- **Кабинет (~35 роутов):** subjects (+delete/erase=GDPR), edges, knowledge(+evidence),
  episodes(+transition), protocols(+state/transition), appointments (book/cancel/complete/noshow/
  reopen/by-subject), expectations(+status), promises + ВЕСЬ market (offer/transfer/refer/settle/
  default), accounts/credit, offerings(+delete), payments/succeed, integration-tokens
  (mint c randomBytesB64 + revoke + GET), outbox GET.
- **/v1 (гейт x-integration-token → живой токен → тенант владельца, P2a):** events (ingest),
  publish, follow, comment, merge-session.
- **Смоук зелёный:** state-machine эпизода (легальный/нелегальный), слот-конфликт брони,
  promise-settle, v1-цепочка publish→follow→comment с эмодзи, 401 на битый токен, GDPR-erase
  (v1-посетители остаются — атрибуция владельцу токена by design).
- docs/edsl-intro.md сохранён (№19).
- **A1 RBAC-порт ✅ (2026-07-07):** `defaultPolicy` (anon/owner[cabinet:use]/admin[admin:use]+inherits
  owner) в PG-сервере; `rolesOfLogin` = Tx-программа (byCol role_assignment.subject; пусто⇒["owner"] —
  аутентифицированный юзер владеет своим кабинетом, НЕ anon); `withTenant` резолвит (тенант,роли)
  одним Tx и гардит `can defaultPolicy roles (pathPerm path)` перед хендлером; privPaths→admin:use
  (/auth/users,/payments/succeed,/credit). byCol role_assignment.subject добавлен в реестр
  (Verbs.byColSupported+strField). Смоук: owner→кабинет 200/credit 403; admin→всё пропущено
  (404=нет счёта, не 403); без/битый токен→401.
- **A4 социальные читалки ✅ (2026-07-07):** /v1/{feed,thread,showcase} — Tx-программы fetch+fold
  (scan edges+entitlements+resources → чистая Social-функция → энкод ContentView/ThreadView с
  teaser-стрипом payload у locked). `resolveViewer` (identity→subject, 0=аноним, читалки НЕ создают
  субъектов). Продел настоящий `now` (окна entitlement). Смоук: тред depth 0/1 payload виден;
  **лента ПЕРСОНАЛЬНА** (fromFeedAuthor=own∨follows) — vis2 пусто → после follow(vis1) видит post A;
  аноним лента пуста by design. Это ПЕРВЫЕ bucket-D сайты — кандидаты в query-EDSL когда станут
  горячими (сейчас 3 full-scan/запрос — приемлемо).
- **A5 транспорты воркера ✅ (2026-07-07):** `deliverVia` перенесён из WAL-сервера ВЕРБАТИМ —
  webhook (подписанный POST, HMAC over topic.body, X-Cxm-Signature/Timestamp) + email (pipe RFC822
  в CXM_SENDMAIL, ""=log-stub) + runPipe-FFI (shell, исключения→False→backoff). Env: CXM_SENDMAIL/
  CXM_MAIL_FROM/CXM_WEBHOOK_SECRET; newHttpClientManager. Смоук: CXM_SENDMAIL="cat >> mbox" →
  реальное RFC822-письмо (заголовки + charset=utf-8 + токен верификации в теле), воркер "email→sent".
- **A6 чаттинес ЗАМЕРЕНА ✅ (2026-07-07):** `server/PgBench.agda` (бинарь `pg-bench`) — round-trip'ы
  на атом (счётчик в шве драйвера `PgConn.pgStmtCount/pgStmtReset` — считает execConn/queryConn,
  т.е. BEGIN+верболы+COMMIT; физический connect через newPool НЕ считается → метрика транспорт-
  независима) + wall-clock (медиана 9 прогонов, монотонный ns, ВКЛючает v1 connect-per-txn).
  Живой PG 17 на loopback (scratch):

  | атом | round-trips | wall медиана | wall min |
  |---|---|---|---|
  | identity-bind-notify | 13 | 9.2 ms | 8.5 ms |
  | booking-cancel | 18 | 11.2 ms | 10.2 ms |
  | promise-stake-settle | 37 | 16.7 ms | 15.8 ms |
  | cascade-delete-deep | 39 | 18.7 ms | 16.8 ms |

  **Вывод (два независимых рычага, оба — ПОСЛЕ катовера, не блокеры):**
  1. **Фиксированный ~4-5 ms/атом** (линейный фит: identity 13 RT/9.2 ms → cascade 39 RT/18.7 ms даёт
     ~0.35 ms/statement + свободный член ~4.7 ms). Этот свободный член — connect-per-txn v1 (newPool
     открывает свежее физ-соединение на атом). На loopback это 25-50 % латентности дешёвых команд;
     по сети (TCP+TLS+auth хендшейк) он на порядок больше → **это ровно то, что снимает pgbouncer
     ИЛИ driver-v2 (персистентный коннект), НУЛЁМ изменений выше шва** (TxRunner — единственная
     сменная деталь). Рекомендация: до пиковой нагрузки — pgbouncer перед v1; driver-v2 — апгрейд.
  2. **13-39 round-trip'ов на атом** — это чаттинес, которую коллапсирует PHOAS/selective-слой
     (один SQL-батч/CTE на команду): каскад 39→1 сэкономил бы ~0.35 ms×38 ≈ 13 ms на loopback и
     кратно больше по сети. Плата за неё — лямбды-биндеры (отложено осознанно до катовера).
  Ни один рычаг не нужен для запуска: 9-19 ms/атом на loopback для community-нагрузки приемлемо.
  Это ЗАКРЫВАЕТ список «до катовера».

- **★ РЕШЕНИЕ пользователя (2026-07-07): НИКАКОЙ миграции WAL→PG.** WAL — брошенный эксперимент,
  прод-данных для переноса нет; PG-стор стартует С ЧИСТОГО ЛИСТА (genesis DDL + ledger + seed
  тенантов/админа). Бинарь `migrate-wal-pg` (и `server/MigrateWalPg.agda`) — **OBSOLETE, не путь
  катовера**; остаётся лишь как исторический потребитель Registry (можно снести вместе с WAL).
  «Катовер» теперь = **просто деплой `cxm-server-pg` на свежий PG + верификация в проде**; когда
  PG-часть подтвердится, пользователь САМ удалит код WAL-датабазы (Commands/Txn/Wal/Api + стор).
  Единственный *предеплойный* шаг с нашей стороны — **заморозить `cxmHistory` в литерал** (включает
  migration-watch: далее изменение схемы без миграции ⇒ не компилируется).

- **★★ WAL-КОД УДАЛЁН (2026-07-07) — пользователь: «можно и сейчас удалить … надо чистить».**
  Не отложено до катовера — снесено сразу (новый проект без WAL, старый сайт интегрируется через /v1).
  Сначала РАСЦЕПЛЕНИЕ общих кусков, чтобы PG-путь остался зелёным:
  * `Cxm.Store.Base` ужат до НЕЙТРАЛЬНОГО (`Err` + позиции индексов; убраны `Base`-запись/`CxmOp`/
    `apply`/IndexedMap) — PG-путь импортил только это;
  * `Cxm.Inference` стал ЧИСТ (удалён Txn-хвост `rebuildHypotheses` + импорты Txn/Interface);
  * `KRevision` переехал в `Cxm.Knowledge`; `debit`/`backoffSec` — локально в `CommandsV`;
  * `Registry.Dump` потерял колонку `dRows`/`tscan` (проекция для сеятеля) + импорт Interface.
  Затем УДАЛЕНО: cxm — `Commands`/`Txn`/`Api`/`Worker`/`All`/`AllIO`/`Query`/`Store.{Interface,Tx2,
  VerbsBase,Codec,Wal}` + WAL-тесты (Commands/Store/Query); server — `CxmServer`/`MigrateWalPg`;
  фреймворк — `StoreTxnTest`/`IndexedMapTest`; agdelte-store — `IndexedMap`/`NatMap`/`WAL`/`Txn`
  (Storage.FFI ОСТАВЛЕН — им пользуется PG: FreeIO+Pg). Харнесс: сняты таргеты `cxm-server`/
  `migrate-wal-pg`/`store-txn-test`/`indexedmap-test` (package.json+cabal). `check-layering.sh`
  переписан под PG-only (G1 драйвер/IO только в Store.Pg; G2 guardedness только там; G3 L1/L5 не
  трогают Store/драйвер) — зелёный. **Проверка: gen+build cxm-server-pg/pg-diff/pg-bench зелёные;
  `pg-diff` ALL GREEN (native≡PG, семантика сохранена); layering-guard зелёный.** Доки обновлены
  (MODULES.md слои/каталог, framework CLAUDE.md, edsl-intro). Остаток стор-EDSL — см. раскладку.

- **★ `rebuildInferenceV` ЗАКРЫТ (2026-07-07)** — единственный функциональный пробел от чистки
  (кабинет Ф4 «перестроить вывод» был WAL-only, не портирован). Порт на верболы в `Cxm.CommandsV`:
  PER-SUBJECT + owner-scoped (lockRoot субъекта → require+guard tenant → clear ACTIVE-гипотез через
  byIx+del → re-derive из событий субъекта чистой `inferHypotheses` → insert fresh). SETTLED
  (REFUTED/CONFIRMED/SUPERSEDED) сохраняются (§4.1); идемпотентно. Роут `POST /knowledge/
  rebuild-inference` (cabinet:use). pg-diff-сценарий `inference-rebuild-idempotent` (двойной
  rebuild ⇒ ровно 1 «unmet-need») — **ALL GREEN (8/8), native≡PG**. Паритет с WAL-оригиналом
  (audit #C): не консультируется с retained-refutations перед пере-предложением (MVP-правила).

## АУДИТ wave-1 (2026-07-07, вечер) — 3 находки, ВСЕ закрыты и проверены живьём
- **H1 (TOCTOU, наш же анти-паттерн):** /notifications делал check (ownedTo) и enqueue ДВУМЯ
  транзакциями. Фикс: один атом (`ownedTo >>=T guardT Forbidden >>T enqueue`). Live: unverified →
  атомарный 403. (Косметика: сообщение стало generic "forbidden" — приемлемо.)
- **H2 (crash-safety boot):** шаг миграции (DDL + ledger-INSERT) шёл автокоммитами → падение
  между ними вешало бы будущие неидемпотентные шаги (ADD COLUMN без IF NOT EXISTS) навсегда.
  Фикс: BEGIN…COMMIT вокруг шага+ledger (PG DDL транзакционен — конвенция Server.Migrate);
  applied_at = настоящий now. Live: чистый boot «applied: 29» → рестарт «applied: 0».
- **H3 (регрессионная сеть G2):** bool-индекс не был покрыт pg-diff → сценарий
  bus-dispatch-bool-index. НЕМЕДЛЕННО окупился дважды: PG-сторона G2 подтверждена
  (dispatched=1;processed=1), а НАТИВНАЯ упала громко — E2-гард поймал отсутствие tcBusEvent в
  ixExtract (вместо тихого []). Добавлен экстрактор → **pg-diff 7/7 ALL GREEN**.
- **Проверено, ОК:** auth-поверхность (401 без токена — строже WAL-фолбэка; timing-oracle
  логина = паритет с WAL); изоляция читалок (byTenant/kTenant-фильтр, без existence-оракула);
  worker at-least-once; deliverStub помечает webhook как email (косметика транспортной заглушки).

## ★★ MILESTONE (2026-07-07): PG-СЕРВЕР ЖИВ — `cxm-server-pg` (wave-1), e2e на живом PG 17
- **`server/CxmServerPg.agda`** (цель `cxm-server-pg`): boot = ledger-миграции (schema_migrations
  над cxmHistory, по-шагово, идемпотентно) → seed (defaultTenant + ensureAdminV) → listen.
  Каждый запрос = одна PG-транзакция (runCxmTx над connectPerTxn v1). Boot-guard (weak secret).
- **Wave-1 поверхность (e2e-смоук зелёный):** /health, /auth/{register,login} (bcrypt+JWT),
  /subjects POST/GET (byIx byTenant), /identities (bindIdentityNotifyV — ОДНО-атомная ревизия
  в проде!), /verify-identity (HMAC), /knowledge (+by-subject), /notifications (verified-guard),
  PG-воркер (forkLoopNudged: dueOutbox→deliver→markSent/Attempt, remindDue, dispatchBus) + nudge.
  Смоук: 403-до-verify → nudge-письмо ~1с → verify по токену ИЗ ПИСЬМА → 200 + юникод/эмодзи
  насквозь → изоляция drB=[] → битый токен 403.
- **Находка G2 (live!):** byIndex по CBool-колонке (bus_event.processed) — PG отвергает
  boolean=integer → воркер-тик умирал ДО доставки. Фикс: `ixKeyLit` в Exec рендерит ключ
  по ТИПУ индексной колонки (из схемы: CBool→TRUE/FALSE) + `idxColTys` в Tables.
  Плюс setLineBuffering в PG-main (лог был буферизован).
- **Осталось до полного катовера (wave-2+):** RBAC-authz порт (pathPerm+scopedRolesOfV+can),
  /v1 site-поверхность + социалка (publish/comment/feed — feed-читалки = query-EDSL кандидаты),
  query/decision/reliability-читалки, psych-пак, реальные транспорты воркера (sendmail/webhook —
  скопировать deliverVia), замер чаттинеса, катовер + заморозка cxmHistory.

## ★ MILESTONE (2026-07-07): LIVE-ДИФФ ЗЕЛЁНЫЙ — native ≡ PG на живом PostgreSQL 17.10
- pg-diff: 6/6 сценариев ✓ с первого полного прогона (identity/knowledge/booking/promise-stake/
  gdpr/abort) — advisory-локи, proof-gated стейк, GDPR-редакция, ROLLBACK работают на реальной базе.
- **Находка G1 (первая минута live!):** hpgsql `queryJson` ОБОРАЧИВАЕТ запрос в подзапрос
  `SELECT coalesce(json_agg(_q),'[]')::text FROM (<sql>) _q` ⇒ (а) query-стейтменты НЕ могут иметь
  хвостовую `;` — снята со всех SELECT-генераторов и inline-запросов Exec, голдены обновлены;
  (б) форма JSON подтверждена (json_agg объектов с именами колонок — допущение JsonRow верно);
  (в) void-SELECT (advisory lock) через обёртку работает. Exec-путь (`execSql`) `;` терпит.
- Инфраструктура: `cxm-core/scripts/pg-scratch.sh` — одноразовый юзерспейс-PG на NixOS
  (initdb+pg_ctl в /tmp, 127.0.0.1:55432, trust; `-k` против недоступного /run/postgresql).
  Scratch-база оставлена ЗАПУЩЕННОЙ (stop: `scripts/pg-scratch.sh stop`).

## Фазы и статус
- **Ф0. Schema→SQL кодеки** — ✅ DONE, всё `refl`-доказано (`Agdelte.Storage.SQL` + SQLTest):
  DDL (+вторичные индексы), INSERT, UPSERT (ON CONFLICT pk DO UPDATE), DELETE by pk, SELECT
  (all/byNat/byStr/page). Остаток: JSON-результат → Row → V декод; FK-эмиссия из CFK.
- **Ф1. `Tx` freer** — ✅ ядро DONE (`Agdelte.Storage.Free` + FreeTest, `--safe`): реифицированные
  верболы `call r k`, ДВА интерпретатора. **Fork-1 закрыт лучше ожиданий: тотально БЕЗ sized types и
  БЕЗ TERMINATING** (континуация — поле конструктора ⇒ `k x` структурно меньше, принцип W-типов).
  Нативный хэндлер + lock-чекер доказаны refl (RYW, реджект незалоченной записи, short-circuit).
  Остаток: PG-интерпретатор (ждёт драйвер).
- **Ф1b. query-EDSL** — ✅ вертикальный срез DONE (`Agdelte.Storage.Query` + QueryTest): single-table
  conjunctive-filter + COUNT; колонки по имени под `T (hasNatCol …)`-гардом (idxCol-приём, без
  зависимого плюмбинга); нативный фолд + compileCount, оба `refl`-пиннуты. Остаток: live-дифф на PG;
  верболы по мере горячей нужды (sum/group/order/join).
- **Ф2. Порт домена**: **ИНФРАСТРУКТУРА ГОТОВА (2026-07-06):**
  - `Cxm.Store.Verbs` ✅ — полный Req/Ans GADT на ВСЕ 28 таблиц + `rByCol` (U2 закрыт) +
    эргономичный слой (get/require/put/del/byIx/byCol/scan/fresh/lockKey/lockRoot и
    **`lockRoots`** — канонический порядок ВНУТРИ комбинатора) + `rootOf` (карта агрегат-корней:
    subject-центрично; evidence→knowledge; transitions→episode; system-строки → сами) +
    `appendOnly` (rDel событий отвергается — зеркало tdel=nothing) + `strField` (byCol-колонки:
    identity.channel/external_id, user.login, payment.ext_id, protocol.name, int_token.token) +
    `_≟_` c пруфом (для dependent-override чистого стейта).
  - `Cxm.Store.VerbsBase` ✅ — нативный хэндлер над Base (runtime): tableOf/putOp/delOp ×28,
    дисциплина + A3 + append-only.
  - `Cxm.Store.VerbsTest` ✅ — ЧИСТЫЙ хэндлер над function-state `(t : TableCode) → List (ℕ × Val t)`
    (один хэндлер на все 28 таблиц, override через ≟) + 8/8 refl: find-or-create через
    эргономичный слой (bindIdentityV с bounded byCol вместо scan), идемпотентность, cross-tenant,
    breach дисциплины, **lockRoots даёт ОДИН канонический порядок при любом порядке аргументов**,
    append-only флаг. byIx в чистом хэндлере — [] (семантика индексов: runtime+PG; ixField добавим
    по мере порта команд).
  - **ПОРТ, ПАЧКА №1 ✅ (2026-07-06): `Cxm.CommandsV`** (identity/subject кластер), 15/15 refl в
    VerbsTest. Портовые решения (прецеденты для остальных пачек):
    * `bindIdentityV` — УСИЛЕН vs сырого оригинала: lockRoot + existence + tenant-guard + bounded
      byCol (не scan);
    * `verifyIdentityV` — паттерн peek → lockRoot → RE-READ под локом + Conflict-guard «корень
      не уехал» (RC-safe check-then-write);
    * `resolveOrCreateSubjectV` — ПЕРВЫЙ боевой lockKey: advisory (nsIdentityCreate,
      hashKey "ch:ext") сериализует create-if-absent;
    * `enqueueNotificationV` + **queue-экзекция**: outbox/busEvent освобождены от root-дисциплины
      для put (fresh-id append, один потребитель — воркер) — `queueTable` в Verbs, оба хэндлера;
    * `bindIdentityNotifyV` — **ревизия двух-коммитного postBindIdentity**: bind + письмо = ОДИН
      атом; тело письма — host-glue `ℕ → String` (Api владеет секретом и строит HMAC-токен от
      fresh-id). Тест: оба ряда после одного прогона, тело замкнуто на fresh id.
    * инфраструктура: `hashKey` (djb2) + `nsIdentityCreate` в Verbs.
  - **ПОРТ, ПАЧКА №2 ✅ (2026-07-06): knowledge/episode** (createKnowledgeV — билдеры §4.1
    verbatim; updateKnowledgeV — peek→lockRoot(kSubject)→re-read + Conflict-guard + FACT-инвариант;
    attachEvidenceV — evidence рутится в СВОЁМ knowledge (lockRoot tcKnowledge); createEpisodeV —
    initial state из протокола). 24/24 refl суммарно. Зеркалированы private isFactK/regradesConf
    из старого Commands (схлопнуть при его выводе из эксплуатации); revise-хелперы — из
    Cxm.Inference (strengthen/weaken/confirm/refute/supersede).
  - **ПОРТ, ПАЧКА №3 ✅ (2026-07-06): appointments/payments** (30/30 refl суммарно):
    * `bookAppointmentV` — **УСИЛЕН: закрыта double-booking гонка.** Busy-check читает ЧУЖИЕ
      appointments того же ресурса → subject-root не сериализует конкурентов; memory-image спасала
      глобальная сериализация. Фикс: `lockKey (nsBooking, resource)` сериализует check→insert
      per-resource (res=0 — сентинел без строки → row-lock невозможен, advisory обязателен).
      Advisory ПЕРЕД row-локами — глобальный порядок плана. Тесты: overlap→Conflict, completed
      не считается busy;
    * `apptTransitionV` (cancel/noShow/complete) — peek→lockRoot(apSubject)→re-read +
      InvalidTransition для не-Scheduled;
    * `creditV` — эталон balance-safety: lockRoot account (A3 даёт и existence) → re-read → put;
    * `grantEntitlementV` — subject-rooted, без tenant-guard (как оригинал, internal);
    * `resourceBusyV` — scan-based как оригинал (bucket-A оптимизация на byIx — потом);
      `nsBooking = 2` в Verbs; зазеркален приватный `apScheduledᵇ`.
  - **ПОРТ, ПАЧКА №4 ✅ (2026-07-06): каскады/GDPR** (44/44 refl суммарно):
    * `cascadeDeleteSubjectV` + `deleteEpisodeDeepV`/`deleteKnowledgeDeepV` — иерархия корней:
      deep-удаления берут ПРОМЕЖУТОЧНЫЙ корень (transitions/deviations → lockRoot episode;
      evidence → lockRoot knowledge). Вложенные локи под эксклюзивным subject-корнем
      дедлок-безопасны (кто-то другой на тот же subject сериализуется НА subject'е).
    * **`altRoots` (новое понятие дисциплины):** ребро = СВЯЗЬ — любой конец вправе её
      разорвать/создать → у edge два допустимых корня (seFrom первичный, seTo альтернативный).
      Иначе каскад не смог бы удалить ВХОДЯЩИЕ рёбра (их первичный корень — чужой незалоченный
      subject). Хэндлеры проверяют heldAny(rootOf ∷ altRoots). Тест: edge 21 (2→1) удалён под
      локом субъекта-1 ★.
    * `gdprEraseSubjectV`/`scrubEventsForV` — редакция append-only лога (put событий под
      subject-корнем) + каскад; тест: событие ВЫЖИЛО с payload "[erased]", subject стёрт.
    * чистый хэндлер дорос: `ixField` (регистр ℕ-индексов ×13 таблиц — честный byIx),
      `heldAny`, keyOf-баг пойман тестом (tcEvent отсутствовал → редакция легла под ключ 0 —
      44-й тест его и выловил).
    * `forEachTx` (каскадный примитив) в Verbs.
  - **ПОРТ, ПАЧКА №5 ✅ (2026-07-06): social/owner/protocol/expectations/tokens** (52 refl суммарно):
    * `addEdgeV`/`followSubjectV` — lockRoots ОБОИХ концов (канонический порядок → конкурентные
      addEdge на одну пару не дедлочат); тест пиннует порядок локов;
    * `registerOwnerV` (+`createUserV`) — tenant+user+assignment под ОДНИМ advisory
      (nsOwnerRegister, hashKey login) — дубль-регистрация сериализуется;
    * `createExpectationV`/`setExpectationStatusV`, `createPromiseV` (simple; PromiseDeclared
      журналится через `appendEventV`), `createProtocolV`;
    * `transitionEpisodeV` — state-machine: lockRoots subject+episode, legality по protocol-графу
      (byIx ptByProtocol + hasTrans), transition-строка + LifecycleChange-событие; тесты:
      легальный переход 100→200, нелегальный → InvalidTransition;
    * `createIntegrationTokenV` (advisory nsTokenMint) / `revokeIntegrationTokenV` (self-root
      лок + owner-guard; cross-tenant → NotFound);
    * **РЕШЕНИЕ (важное): absent lockRoot = NotFound** (не Invariant) — доменная форма ошибки
      (existence-hidden 404, совместимость с оригиналами lockRoot-first команд); анти-паттерн
      «лок свежего id» ловится по-прежнему, как NotFound. Оба хэндлера + A3-тест обновлены.
      NS-реестр: 1 identity-create, 2 booking, 3 owner-register, 4 token-mint.
  - **EXEC ✅ (2026-07-06): `Cxm.Store.Pg` — верболы → SQL, мост к драйверу ГОТОВ** (typecheck
    против PgConn-контракта; запуск = прагмы драйвера):
    * каждый вербол = один стейтмент через ДОКАЗАННЫЕ кодеки (SQL.rowUpsert/deleteById/selectBy*)
      и ДОКАЗАННЫЙ декодер (JsonRow.decodeRows/decodeIds/rowPk); `runCxmTx = FreeIO.runTxPg exec`;
    * `rLockRoot` → `SELECT "id" … FOR UPDATE` (пустой ответ ⇒ NotFound — A3-семантика 1:1 с
      нативными хэндлерами); `rLockKey` → `pg_advisory_xact_lock(int4,int4)`; `rFresh` →
      `nextval('cxm_id_seq') AS "id"`; `rDel` событий отвергается ДО SQL (append-only);
    * **ixColName ВЫВОДИТСЯ из схемы** (p-я idxCol-колонка) — позиции совпадают с IndexedMap
      by construction, ручного маппинга нет;
    * `Cxm.Store.Tables` — TableCode-проводка (name/schema/toRow/fromRow ×28; строгий decode →
      Maybe) + **мост-refl** `map (name,schema) allCodes ≡ map … dumps` — Tables и Registry не
      могут разъехаться;
    * **hashKey ограничен 31 битом** (advisory-объиды — int4! критический фикс по пути);
      JsonRow дорос: `decodeIds`, `rowPk`; страж G3 расширен: Store/Pg — легитимный IO-адаптер
      (TODO: G2-паттерн расширить на Agdelte.Storage.(FFI|PgConn|Postgres));
    * дисциплина НЕ перепроверяется в Exec (локи держит сам PG; «взяла ли их команда» —
      проверяют нативные хэндлеры в тестах). Это документированная асимметрия.
  - **ПОРТ, ПАЧКА №6a/6b ✅ (2026-07-07): accounts/offerings/payments + promise-market**
    (71 refl суммарно, 15 команд):
    * `chargeV` — **proof-gated debit перенесён в типе** (`amt ≤? balance` → `debit … pf`);
      тесты: 100−30=70; 999 → Insufficient;
    * promise-market целиком (createPromiseDirected/list/transfer/refer/settle/default/markX):
      паттерн peek→lockRoots(subject + `accRoots` затронутых счетов, E3-пре-лок ДО суб-команд)→
      re-read→guards→stake-ops→журнал. Тесты: settle возвращает стейк (100→130) + журнал
      `{"promise":70}`; default маршрутизирует штраф (penaltyTo 0→30) атомарно со статусом;
      **★ referral proof-gated: новый должник без денег → Insufficient и ПОЛНЫЙ откат атома**;
    * `markPaymentSucceededV` — идемпотентность доказана (двойной прогон в одном атоме: одна
      entitlement, второй нет); **сироты-платежи** (subject 0): `rootOf tcPayment` ветвится —
      сирота рутится в себя; помечен, entitlement не выдаётся;
    * `fulfillOfferingV` (fulfilment-as-data), `recordPaymentV`, `findPaymentByExtIdV` (bounded
      byCol), `openAccountV`/`createOfferingV`/`softDeleteOfferingV`;
    * **`nsSelfCreate = 5`** — generic advisory для self-rooted создателей (objid=tenant;
      per-tenant сериализация создания — throughput-заметка → PHOAS).
  - **ПОРТ ЗАВЕРШЁН: волны 6c-6f ✅ (2026-07-07). Ф2 = 100%: 71 команда, 84 refl.**
    * 6c resources/разговоры: `commentOnV` (узел+mentions+peer-событие одним атомом, ConvCtx-
      наследование, F4-гард аудитории — тест: чужак Forbidden), publish/update/updateOwn
      (owner-guard тест)/link/unlink/requireAnchorV/anchorParticipantV (getBase изгнан);
    * 6d worker: drain/dueOutbox (backoffSec переиспользован)/markAttempt/markSent/dispatchBus/
      reopen + напоминания. **Находка порта: remindDueAppointmentsV сортирует subject-локи
      ascending** — воркер против addEdgeV мог дедлочить; E3 соблюдает и воркер;
    * 6e lifecycle: provisional/softDelete/mergeV (оба корня)/mergeSessionV (alias+promote,
      тесты обоих путей)/`ingestSiteEventV`+`ingestPeerEventV` — **УСИЛЕНЫ**: advisory до
      lookup (дубль-ingest одного нового cookie больше не плодит два provisional);
      `lockKeyPair` (два advisory отсортированы — peer-ingest не дедлочит сам с собой);
    * 6f admin/seed: ensureProtocolV/ensureAdminV — **find-then-create гонки закрыты advisory
      до lookup** (тест: двойной ensureAdmin в одном атоме = один user); addProtocolState/
      Transition (root=protocol), assignRole/revokeRoleV (локи по scan-порядку = id-ascending
      во всех трёх интерпретаторах), scopedRolesOf, findUserByLogin (bounded byCol login),
      seedTenantsV.
  - ОСТАТОК до катовера: подключение Api-хендлеров к CommandsV + PG-main + boot-раннер.
    **При драйвере: прагмы → live-дифф native≡PG (id-нечувствительный) → чаттинес → катовер.**
- **Ф3. Катовер (переопределён 2026-07-07)**: НЕ миграция — деплой `cxm-server-pg` на СВЕЖИЙ PG
  (genesis+ledger+seed тенантов/админа), верификация в проде, затем пользователь удаляет WAL-код.
  Предеплой: заморозить `cxmHistory` в литерал. Чаттинес замерена (A6). SERIALIZABLE НЕ включать.

## Среда
stdlib v2.4-35 (master, pull 2026-07-05; прежний ref в /tmp/stdlib-prev-ref.txt), Agda 2.9.0,
все .agdai сброшены, полный gen:cxm-server на новой stdlib — зелёный.

## Зарезервировано: вложенные транзакции (решение пользователя 2026-07-06)
Сейчас и надолго НЕ нужны, но принципиальная возможность сохраняется — и она открыта конструкцией:
- PG: SAVEPOINT/ROLLBACK TO/RELEASE — обычные строки через execConn, **контракт PgConn не меняется**;
- язык: ОДИН новый конструктор `sub : Tx B → (E ⊎ B → Tx A) → Tx A` (провал под-программы ловится,
  не абортит внешнюю) + по клаузе в интерпретаторах (нативный: откат стейта к до-sub; PG: savepoint
  со счётчиком глубины); PHOAS-слой — комбинатор tryC поверх того же узла.
- **Тонкость (обязательна при реализации):** PG НЕ освобождает row/advisory-локи при ROLLBACK TO
  SAVEPOINT → нативный интерпретатор на откате восстанавливает СТЕЙТ, но СОХРАНЯЕТ локи — монотонность
  локов (структурный 2PL) держится и с вложенностью; эталон совпадает с PG.

## Реактивность (решения 2026-07-05)
- **LISTEN/NOTIFY НЕ строим** (аргумент пользователя: «всё проходит через нас, а не через постгрес»).
  Single-process: воркер будится **in-process post-commit nudge**; при будущих репликах фанаут —
  app-уровневый bus, PG-NOTIFY лишь запасной вариант. Слот `awaitNotification` зарезервирован
  комментом в PgConn (аддитивно).
- **Nudge РЕАЛИЗОВАН + smoke:** `Agdelte.FFI.Server.nudgeWorker` (глобальный `MVar ()`, tryPut —
  без потерянных пробуждений) + `forkLoopNudged` (сон прерываем nudge'ем; nudge во время тика
  запоминается). Продюсеры: postBindIdentity (письмо верификации: было ≤CXM_WORKER_SEC, стало
  мгновенно — smoke: доставка через ~1с при интервале 60с), /notifications, бронь в паке,
  reportAudit. Один потребитель — воркер-цикл (audit-бот остаётся forkLoopEvery).

## Сделано 2026-07-05 (день, всё typecheck-зелёное; runtime-куски ждут драйвер)
- **Ф0 read-половина:** `Storage.JsonRow` — чистый (stdlib-only) парсер JSON-подмножества PG
  (плоские объекты, скаляры; fuel-тотальный) + `rowFromObj` по ИМЕНИ колонки (order-robust; absent
  key ≡ NULL → приемлет только CMaybe) + `decodeRows`. 7/7 refl-тестов (эскейпы, \u-кириллица,
  NULL↔CMaybe, реджекты).
- **Ф0 write-довесок:** `rowUpsert` (ON CONFLICT pk DO UPDATE; pk-only → DO NOTHING), `deleteById`,
  `selectAll/ByNat/ByStr/Page` (page: ORDER BY pk — конформный пиннинг) — все refl-пиннуты.
- **Ф1 PG-сторона:** `Storage.FreeIO` — generic интерпретатор `runTxPg : TxRunner → Exec → Tx A →
  IO (E ⊎ A)`: BEGIN → пошаговый фолд (verb-level ошибка ⇒ ROLLBACK) → COMMIT/ROLLBACK. Домен даёт
  `Exec = Conn → (r : Req) → IO (E ⊎ Ans r)`. Typecheck против PgConn-контракта.
- **Ф2 proof-of-shape:** `Cxm.Store.Tx2` — verb-GADT среза (subjects+identities): lockRoot/lockKey/
  get/byIndex/scan/put/del/fresh; НАТИВНЫЙ хэндлер над `Base` (runtime) + ЧИСТЫЙ хэндлер (assoc-list,
  та же дисциплина) для compile-time; портирована команда `bindIdentity2` (lockRoot → tenant-guard
  (NotFound, existence-hidden) → find-or-create). 5/5 refl: create/idempotence/cross-tenant/
  незалоченная запись=abort.

## Миграции схемы (2026-07-06) — EDSL вместо внешнего средства, ядро ГОТОВО
Требование пользователя: список миграций с откатом, корректнее внешних миграторов. Реализация —
`Agdelte.Storage.Migration` (+MigrationTest, 9/9 refl):
- **`MigStep`-термы** (createTable/addColumn(+DEFAULT для NOT NULL)/addIndex/dropIndex/dropColumn/
  dropTable) с ТРЕМЯ интерпретаторами: `up` (SQL вперёд, по-стейтментно — форма A1), `down`
  (SQL отката; `nothing` = ЧЕСТНО необратимый шаг — раннер не откатывает дальше), `applyStep`
  (чистая модель над SchemaSet).
- **★ Верифицированная цепочка:** `migrate history [] ≡ текущие схемы кода` — refl. Изменил схему
  без миграции (или наоборот) ⇒ НЕ КОМПИЛИРУЕТСЯ. Внешние миграторы такого не могут в принципе
  (нет источника истины). END-append колонок = тот же Tier-1, что у WAL-кодека.
- **Раннер:** переиспользуем конвенцию существующего `Agdelte.Server.Migrate` (ledger
  schema_migrations, шаг атомарно: тело+bookkeeping одной транзакцией), но кормим СГЕНЕРИРОВАННЫМИ
  стейтментами вместо *.sql-файлов; rollback-режим = down-цепочка от версии N + удаление ledger-строк.
  Wiring — после драйвера (или через приём «один exec-вызов = одна неявная транзакция»).
- **★ ROLLBACK-РАННЕР + WELLFORMEDNESS ГОТОВЫ (2026-07-07).**
  * `Storage.Migration.checkMigrations` — 4-й интерпретатор (PURE): каждый шаг проверяется против
    модели, эволюционирующей по предыдущим (дубль/отсутствие таблицы|колонки, индекс/дроп несуществ.
    колонки, дубль-колонка внутри CREATE, `CMaybe(CMaybe)`). Refl-гейт в реестре: `checkMigrations
    cxmHistory [] ≡ []` (малформ-миграция ⇒ compile error ДО эмиссии SQL). Зубы доказаны 6 негатив-
    refl в MigrationTest (стаб `λ _ _ → []` их бы завалил).
  * `server/PgRollback.agda` (бинарь `pg-rollback`) — down-раннер: читает ledger newest-first, берёт
    последние N (env CXM_ROLLBACK_STEPS=1), резолвит `down` из cxmHistory, применяет newest-first
    (BEGIN→down→DELETE ledger-строки→COMMIT на шаг). ALL-OR-NOTHING: если любой шаг в диапазоне
    необратим (mDropColumn/mDropTable→nothing) или id вне истории — ОТКАЗ, не трогает ничего.
    Live-проверено на scratch: happy (id 1=create-seq → откат, ledger пуст, sequence снят) +
    refuse (id вне диапазона → REFUSED, ledger цел).
- **Бонус-факт:** комменты Server.Migrate документируют мульти-стейтмент поведение hpgsql ⇒ он на
  SIMPLE-протоколе — A1-риск подтверждённо мягче (ddlList всё равно оставляем — робастнее).
- **РЕЕСТР ГОТОВ (2026-07-06): `Cxm.Store.Registry`** — единый список всех 28 таблиц
  (имя↔схема↔toRow↔Base-проекция, record Dump). Из него выводятся: сидер (`migrate-wal-pg`
  переписан на свёртку реестра — 28 инлайн-строк удалены, расхождение имя/схема невозможно),
  `cxmSchemas`, `genesis` (по mCreateTable на таблицу) и **сторожевой refl-чек**
  `migrate cxmHistory [] ≡ cxmSchemas`. СЕЙЧАС cxmHistory = genesis (выводится) — чек намеренно
  тавтологичен, пока нет прод-PG. **ПРОЦЕДУРА ЗАМОРОЗКИ (обязательна при первом прод-деплое):**
  заменить `cxmHistory = genesis` литеральной копией истории — с этого момента изменение Wire без
  дописанного MigStep ломает компиляцию Registry (стража «схема изменилась → нужна миграция»).
- Остаток: rollback-раннер (down-режим) кодом; wellformedness миграций (уникальность имён колонок,
  запрет CMaybe(CMaybe)); включить Registry в регулярный CI-гейт (сейчас чекается gen:migrate-wal-pg;
  после порта Ф2 PG-сервер применяет cxmHistory на старте → чек попадает в gen:cxm-server).

## АУДИТ, пятый проход (2026-07-07) — последние изменения (пачки 6a-6f, PgConn v1, pg-diff). 2 находки
- **F1 (латентная, класс B1):** порядок `byIx` РАСХОДИТСЯ между интерпретаторами: PG — ORDER BY id,
  чистый — ascending, Base — reverse-insertion (IndexedMap addKey ПРЕПЕНДИТ в bucket). Все текущие
  использования order-insensitive (свип: каскады/drain/hasTrans/remindDue-с-sort ✓). Чинить bucket-
  порядок рискованно (боевой WAL-сервер) → КОНТРАКТ в докстроке byIx: «результат = МНОЖЕСТВО,
  порядок не специфицирован; сортируй сам; first-match запрещён».
- **F2 (fidelity-регрессия, ИСПРАВЛЕНА):** mergeSessionV promote-путь биндил login-identity
  UNverified — оригинал биндил verified=true (логин ДОКАЗЫВАЕТ контроль канала); регрессия ломала
  бы /notifications залогинившимся. Фикс + refl-тест (identity 90 = verified true).
- **Проверено, ОК:** дисциплина всех ~36 команд пачки 6 (каждый put/del под корнем/advisory/
  queue-экзекцией; orphan-payment self-root; mention/comment под nsSelfCreate; peer-ingest
  lockKeyPair сортирует advisory; ensureAdmin/registerOwner делят ns по login — сериализуются
  между собой ✓); PgDiff-сценарии детерминированы (id-выравнивание по fresh→put конвенции,
  сравнения order-insensitive); PgConn v1 прагмы (bracket, приватный пул-1); TxRunner
  type-synonym фикс (MAlonzo rank-2 newtype). Отмечена приемлемая асимметрия: Conflict-гарды
  «корень не уехал» defensive-only (корне-определяющие поля в домене неизменяемы) — есть не везде.
- Итог: 85 refl; pg-diff пересобран с F2.

## АУДИТ, четвёртый проход (2026-07-07) — угол: семантика fresh, симметрия вакуумных тестов. 2 находки
- **E1 (семантический контракт):** `fresh` расходится native↔PG вне конвенции: натив ПОДСМАТРИВАЕТ
  счётчик (fresh;fresh без put ⇒ ОДИН id — конвенция старого Txn), PG `nextval` всегда инкрементит
  (⇒ разные id); abort нативно переиспользует id, на PG — дыра. Все ~35 команд сверены вручную:
  каждый fresh немедленно материализуется put'ом ✓ (на таких программах интерпретаторы совпадают).
  КОНТРАКТ записан в докстроку `fresh`; live-дифф обязан сравнивать id-НЕчувствительно через
  aborts; механическое принуждение (fresh→put пара статически) — в PHOAS-слой.
- **E2 (класс C2, но для byIx):** чистый ixField для незарегистрированной позиции молча давал []
  (Base/PG видят реальные строки) → вакуумные тесты. Фикс: `ixExtract : … → Maybe (Val t → ℕ)`,
  незарегистрированная позиция = громкий Invariant + refl-тест (`byIx tcEdge 2` — kind).
- **E3 (правило записано):** ПОСЛЕДОВАТЕЛЬНЫЕ lockRoot-взятия внутри команды тоже обязаны
  возрастать по (code,id) — иерархия parent<child в кодах таблиц это даёт (subject 1 < episode 21);
  свип всех команд: возрастают ✓. Контракт — в докстроке lockRoots.
- **E4 (драйверный чек-лист):** поведение queryJson на void-SELECT (pg_advisory_xact_lock) —
  проверить; emoji-roundtrip (D2) — проверить.
- Итог: 58 refl; 4-й проход дал контракты и симметрию, НЕ баги текущего кода — отдача убывает,
  следующее реальное снятие рисков = live-дифф на драйвере.

## АУДИТ, третий проход (2026-07-07) — угол: boot-path свежего PG, юникод, паритет формул. 2 находки
- **D1 (real, boot-blocker):** `genesis` создавал 28 таблиц, но НЕ `cxm_id_seq` → свежий деплой
  через boot-раннер упал бы на первом же `rFresh` (nextval несуществующей sequence). Фикс:
  `mCreateSequence` в Migration-EDSL (up/down; для табличной модели — id, сторож держится) +
  genesis начинается с него + голдены. (Сидер migrate-wal-pg создавал sequence сам — потому гэп
  прятался: ломался только путь «чистый PG без сидера».)
- **D2 (real, контент сообщества):** \u-суррогатные пары не поддерживались — если JSON-энкодер
  драйвера экранирует эмодзи (😀), парсер выдавал мусор. Фикс: комбинирование пар в
  JsonRow (UTF-16 → код-поинт), одинокие суррогаты — malformed. Refl-доказательство:
  `"hi 😀"` → `"hi 😀"` точно. (Драйверному чек-листу: emoji-roundtrip всё равно прогнать.)
- **D3 (проверено, ЧИСТО):** формула bump чистого хэндлера ≡ `suc id ⊔ n` из Base (обе ветви
  совпадают); индексация 0-сентинелей nullable-FK (fkOrZero) — паритет native/PG (IndexedMap
  индексирует значение ИЗ row, т.е. после fkOrZero, PG хранит ту же 0) ✓.
- Заметка: `Cxm.Store.Pg` пока не входит ни в одну build-цель (typecheck-only) — войдёт с
  драйверным smoke-таргетом.

## АУДИТ, второй проход (2026-07-07) — угол: catchall-паттерны и расширяемость. 3 находки, закрыты
- **C1 (латентная мина):** `_≟_` заканчивается catchall `_ ≟ _ = nothing` → 29-я таблица с забытой
  диагональю НЕ ловится компилятором, и override чистого хэндлера молча перестаёт писать в неё.
  Фикс: refl-пин рефлексивности `map (λ t → isJust (t ≟ t)) allCodes ≡ replicate 28 true` в Tables.
- **C2 (молчаливое расхождение native↔PG):** нативные хэндлеры знают только strField-колонки —
  byCol по незарегистрированной колонке давал бы [] в тестах (вакуумный проход), но НАСТОЯЩИЕ
  строки в PG. Фикс: реестр `byColSupported` в Verbs; ВСЕ ТРИ интерпретатора (pure, Base, Exec)
  громко отказывают по незарегистрированной паре + refl-тест.
- **C3 (незапиненная конвенция):** Exec хардкодит "id" в lock/byIndex/nextval SQL — держалось
  на конвенции. Фикс: refl-пин `pk каждой из 28 схем ≡ "id"` в Tables.
- **Проверено, ОК (без изменений):** таблица "user" — зарезервированное слово PG, но все наши
  эмиттеры всегда квотируют идентификаторы ✓; UPSERT на события легален (редакция GDPR, delete
  запрещён отдельно) ✓; кросс-тенантный resolveOrCreate — fidelity к оригиналу и design
  (identity-bridge сообщества) ✓; порядок в чистом хэндлере = insertion order = id-order при
  монотонных fresh-id ✓ (конвенция сидов — ascending).
- **Чек-лист новой таблицы (записать в MODULES/onboarding):** TableCode+код+≟-диагональ (пин
  поймает), Val/tableOf/putOp/delOp/rootOf (компилятор заставит), appendOnly/queueTable
  (catchall=false — РЕШИТЬ ОСОЗНАННО!), Registry-entry (мост-пин поймает), migration-терм
  (сторож поймает после заморозки), keyOf/ixField в тестовом хэндлере по мере использования.
- Итог: **57 refl**, 15 модулей, оба стража, migrate пересобран.

## АУДИТ выросшей картины (2026-07-06, вечер) — 2 реальные находки + 3 систематизации, ВСЕ закрыты
- **B1 (real, conformance):** `selectAll/selectByStr/selectByNat` были БЕЗ ORDER BY → PG отдаёт
  произвольный физический порядок, а нативные хэндлеры читают id-упорядоченно ⇒ live-дифф
  зафлейкует, а first-match (`mine hits` в bindIdentity) недетерминирован. Фикс: все SELECT
  пиннуют `ORDER BY pk` («мы — стандарт»); сигнатуры получили Schema; голдены обновлены.
- **B2 (real, native-parity):** Exec `rDel` игнорировал affected-count → удаление несуществующей
  строки давало inj₂ tt, а натив даёт NotFound ⇒ расхождение семантик native≡PG. Фикс:
  `affected 0 ⇒ NotFound`.
- **B3 (систематизация):** порядок индексных позиций жил в ТРЁХ местах (Wire idxCol-порядок,
  Base-константы, ixField чистого хэндлера). Пришпилен теоремами: 9 refl-пинов в Tables
  (`idxCols (schemaOf tc…) ≡ точный список`) — переставленный idxCol в Wire ломает компиляцию,
  а не тихо ремапит rByIndex. idxCols дедуплицирован (Tables → Pg).
- **B4:** непокрытые тестами команды пачки №5 получили refl-тесты (createPromiseV + его
  PromiseDeclared-событие `{"promise":3}` одним атомом, createProtocolV, createIntegrationTokenV);
  ixField дополнен tcEvent. Итог: **56 refl-тестов**.
- **B5 (проверено, ОК):** дисциплинная прочность ВСЕХ ~35 портированных команд перепроверена
  вручную (каждый put/del — под своим корнем/altRoot/advisory/queue-экзекцией); зазор не найден.
  strField-колонки сверены со схемами (login/ext_id/name/token/channel/external_id ✓).
- **Осталось как известные не-блокеры:** anyAdvisory щедрый (PHOAS починит статически);
  G2-паттерн стража не покрывает Agdelte.Storage.(FFI|PgConn) (Store/Pg легитимен, но паттерн
  расширить стоит); decode-fail в Exec = Invariant (натив не может так падать — асимметрия
  документирована); пачка №6 не портирована.

## АУДИТ 2026-07-06 (корректность + удобство) — 3 находки корректности + 1 эргономики, ВСЕ исправлены
- **A1 (драйвер-мина):** `schemaDDL` = НЕСКОЛЬКО стейтментов одной строкой; extended-протокол PG
  такое отвергает (simple — ест), а протокол hpgsql неизвестен. Фикс: `ddlList` (стейтменты списком),
  `schemaDDL` переопределён через него (старый refl-тест = regression-доказательство байтовой
  идентичности), `migrate-wal-pg` гоняет DDL по-стейтментно. +refl-тест на ddlList.
- **A2 (миграция не идемпотентна + sequence):** `rowInsert` → pk-конфликт при повторном прогоне
  (падение с частичным состоянием). Фикс: `rowUpsert` (перезапись, безопасный ре-ран) + создание
  `cxm_id_seq` и `setval(…, nextId, false)` в конце (закрыт gap глобальной sequence). Пересобран.
- **A3 (эталон был СЛАБЕЕ PG):** PG `FOR UPDATE` несуществующей строки МОЛЧА не лочит ничего, а
  нативный `rLockRoot` записывал лок для любого id → программа «lockRoot нового id → create»
  прошла бы чекер, но гонялась бы в PG. Фикс: оба хэндлера Tx2 отвергают lockRoot отсутствующей
  строки («use lockKey for creates») + refl-тест. Эталон теперь строже PG — fail-fast.
- **U1 (эргономика, регрессия vs старый Txn):** `requireT tbl err id` (1 строка) превращался в
  get+λwhere+abort (3). Фикс: комбинатор `require t k e : Tx (Val t)` в Tx2; `bindIdentity2`
  ужат — это целевой стиль Ф2-сахара (requireSubject и т.п.).
- **U2 (записано в Ф2):** в срезе НЕТ строкового лукап-вербола → `bindIdentity2` ищет rScan'ом
  (full scan под PG). Полный Req обязан включить `rByCol` (identities ищутся по (channel, ext)).
- **Минорки (приняты):** `CMaybe (CMaybe _)` схлопывает `just nothing` ↔ `nothing` в NULL —
  вложенный Maybe в схеме считать невалидным (wellformedness-проверка — потом); \u-суррогаты
  не поддержаны (документировано); Query `T`-гард при опечатке колонки даёт криптичную ошибку
  типов (терпимо, ловит на компиляции).
- Батарея: 7 модулей + Tx2 + оба стража + пересборка migrate — зелёные; refl-регрессия схемы прошла.

## АУДИТ дня (2026-07-05, вечер)
- **Находка (архитектурная, ВАЖНО):** `NatMap` — ПОСТУЛАТ поверх Haskell `Data.Map` → у Base НЕТ
  правил редукции: **всё, что через Base, refl-непроверяемо принципиально** (только runtime).
  Следствие для «эталона»: compile-time пиннинг — через чистый стейт (сделано в Tx2), live-дифф
  native≡PG — runtime-харнесс над Base-хэндлером (Ф3). Зафиксировано в Tx2-комменте.
- **Находка (гард):** Tx2 сперва получил `--guardedness` рефлекторно → страж G3 поймал (infective
  флаг вне IO-адаптеров); убран — Tx2 чистый. Стражи работают.
- **Пиннинг допущения:** `esc` НЕ дублирует бэкслеши — корректно ТОЛЬКО при
  `standard_conforming_strings=on` (дефолт PG≥9.1). **Драйверный чеклист: не выключать / проверить
  при connect.** (При off — инъекция через `\'`; при дублировании на on — порча данных. Выбор верный,
  но связан с настройкой.)
- **Мелочи (приняты, не баги):** JsonRow игнорирует хвост после `]` (вход только от драйвера);
  dup-ключи в объекте — первый выигрывает; NUL в TEXT PG всё равно не хранит. FreeIO: исключение
  Haskell посреди транзакции → bracket закрывает соединение → PG сам откатывает (implicit rollback) —
  безопасно. nudge при выключенном воркере — безвредный одно-слотовый флажок.
- **Gap-лист (осознанные дыры среза, НЕ прод):** Ф3 — `freshId`→одна глобальная PG-sequence
  (nextId в Base глобален!) + `migrate-wal-pg` обязан `setval` после сида (сейчас НЕ делает);
  Tx2: `anyAdvisory` слишком щедрый (нужна проверка конкретного (classid,objid) per-use-case),
  pure-хэндлер `rByIndex`→[] и `rDel` не смоделированы, полный Req — все 28 таблиц; live-дифф
  и замер чаттинеса — после драйвера.
