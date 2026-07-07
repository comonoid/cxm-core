> **★ ОБНОВЛЕНО 2026-07-07 — стор: Postgres-only.** WAL + in-memory движок УДАЛЁН (движок и старые
> WAL-команды снесены; сервер — `cxm-server-pg` на живом PG). Любые упоминания WAL / memory-image /
> «ждёт драйвера» / «Postgres отложен» НИЖЕ — ИСТОРИЯ. Актуальная модель хранения, статус и контракты:
> **`docs/pg-store-plan.md`**.

# CXM access control — трёхслойная модель (RBAC + owner-policy + platform-floor)

> Статус: план (2026-07-04). Возник из аудита изоляции: data-scoping есть, но **слой авторизации
> отсутствовал** (`authz` в CxmServer = `λ _ _ → pure nothing`, RBAC определён но не enforced).
> Модель согласована с пользователем в диалоге.

## Модель (три слоя, ограждения на каждом)

**Слой 1 — платформенный RBAC (операции): кто что ДЕЛАЕТ.**
- Роли-как-данные (`Agdelte.Auth.RBAC`: `Perm=res×action`, `Role=id+grants+inherits`, `can`). Дефолты:
  `anon` (никаких операторских перм), `owner` (`cabinet:use`), `admin` (`cabinet:use`+`admin:use`).
- **Аноним = роль `anon`** (principal `nothing` → `["anon"]`); привилегии — по доступам, не хардкодом.
- `authz` перестаёт быть заглушкой: principal→роли (из `assignmentsT`), путь→нужный перм (`pathPerm`),
  `RBAC.can` = false → `403`.
- `registerOwner` вешает роль `owner`.
- Перма анонима/ролей — **конфиг**, НО с пределами (ниже).

**Слой 2 — политика владельца (свой контент): кто видит ЧТО.**
- Доступ к опубликованному контенту (blog/тренинги/офферы) настраивает ВЛАДЕЛЕЦ. База есть в соц-слое
  (`visibility` public/followers/entitled, `entitlements`, `listing`).
- **Стандартный режим** = пресеты (public/followers/entitled) — сахар.
- **Продвинутый режим** = владелец пишет произвольные правила (**политика-как-данные**, мини-язык,
  в духе fulfilment/protocols-as-data), тем же интерпретатором. «Почти произвольно» — см. пол.

**Слой 3 — пределы/инварианты платформы (fail-closed).**
- Эффективный доступ = `owner-policy(req) ∧ platform-floor(req)` — пол применяется ПОСЛЕ правил
  владельца, жёсткой маской. Никакое правило слоя 2 не может выдать доступ сверх пола.
- **Жёсткий пол приватности:** приватный кабинет (Knowledge/Episode/Appointment/Expectation о клиентах)
  — ВСЕГДА приватен владельцу, никогда не кросс-тенант и не публичен. Это НЕ «контент под слайдер»,
  а privacy-backbone (та изоляция из аудита). Владелец не может сделать заметки о клиенте публичными.
- **Guardrail на конфиг (footgun-защита):** пределы — тоже конфиг с жёстким дефолтом. Инвариант
  политики проверяется при `runInstance`, **fail-closed**: если публичная/`anon`-роль держит (в т.ч.
  по наследованию) перму из forbidden-set (`admin:*`/user-mgmt/token-mint/payment-confirm/role-assign)
  — инстанс НЕ стартует с внятной ошибкой, а не «тихо едет с anon-admin». Можно юзать `RBAC.SoD` и
  пересечение `effectivePerms anon ∩ forbidden = ∅`.

## Фазы

### RB1 [слой 1] — RBAC enforcement (закрывает аудит #2/#4/#5/#6)
- [ ] `Cxm.Api.pathPerm : (method path : String) → Maybe Perm` — классификация операторских роутов:
      привилегированные (`/auth/users`,`/integration-tokens`,`/assignments`,`/payments/succeed`,
      `/subjects/delete`) → `admin:use`; прочие кабинет/операторские → `cabinet:use`; (login/register/
      me/v1 — до authz, не классифицируются).
- [ ] `Cxm.Api.rbacAuthz : Policy → WalHandle → authz` — principal→роли (`nothing`→`["anon"]`;
      `just login`→ raRoleId из assignmentsT), need=pathPerm, `can`=false → `403`.
- [ ] `registerOwner` → назначить роль `owner` новому юзеру.
- [ ] `CxmServer`: дефолтная Policy (anon/owner/admin) + подключить `rbacAuthz` вместо заглушки.
- [x] **Guardrail + secret-guard (P0, DONE+verified 2026-07-04):** boot-time fail-closed в `main` —
      инстанс ОТКАЗЫВАЕТСЯ стартовать, если `CXM_JWT_SECRET` = дефолт/пуст (форж admin-токена → обход
      RBAC) ИЛИ `publicSafe defaultPolicy` false (публичная/`anon`-роль держит привил.-перму), кроме
      `CXM_DEV=1`. Smoke: дефолт-секрет→FATAL (не служит); strong→служит; dev-override→служит.
      `CXM_TOKEN=""` НЕ флагаем — при strong-секрете RBAC бэкстопит открытый гейт (anon→403).
- **DoD:** smoke: аноним→403 на кабинет/привил.; owner→кабинет ok, привил.→403; admin→всё ok;
      owner видит только свой тенант; мисконфиг anon-admin → отказ старта. All+guards+cxm-server зелёные.

**АУДИТ RB1/RB2 (2026-07-04):** RB2 (AccessPolicy) — чисто (fail-closed, пресеты вбираются точь-в-точь,
canList тоже через движок). RB1:
- **B (ИСПРАВЛЕНО):** `pathPerm` бинарен → системно-финансовые роуты провалились в `cabinet:use`
  (owner мог `/credit` начислить деньги, `/outbox/drain`, `/events/dispatch`). Добавил их в privPaths
  (→ admin). Verified: owner→403, admin→проходит authz.
- **A (флаг, под-вопросом):** `authz` до `ext` → `/psych/*` (9 роутов) теперь под `cabinet:use` (было
  токен-only). Для community (JWT везде) корректно, НО `/psych/availability|offerings` могут быть
  публичным чтением слотов/каталога — если так, нужна лёгкая классификация (public). Требует
  подтверждения продукт-модели `/psych/*`.
- **`/notifications` (флаг):** owner слать на произвольный email = спам-вектор; но owner-напоминания
  клиенту легитимны. Не блокировал (не ломать) — нужно tenant-scoping (только свои субъекты), не admin.
- **Урок:** `pathPerm` слишком грубый (priv/cabinet). Нужен 3-й класс `public` (для client-читалок
  пака) + возможно per-route override. RB1 follow-up.

### RB2 [слой 2] — owner-config доступа к контенту ✅ CORE DONE 2026-07-04
- [x] **Продвинутый режим = policy-as-data.** `Cxm.AccessPolicy` — DNF-грамматика в opaque
      `rVisibility` (§7.4): клаузы `|` (ИЛИ), атомы `&` (И), отрицание `!`; атомы
      `public/followers/entitled/sub:N/node:N`. Парсер+eval+валидатор, **12 refl-тестов** (пресеты
      вбираются; OR; AND+NOT «followers&!sub:42»; fail-closed на мусор/пусто).
- [x] Wired в `Cxm.Social.canAccess` (нейтрально: атомы абстрактны, Social даёт decider). Пресеты
      сохранены (single-atom policy) → полная обратная совместимость. Автор всегда видит своё.
- [x] **Owner-guardrail (не выстрелить простому в ногу):** `compilePolicy` = parse+`wellFormed`;
      невалидное/unsafe → `nothing` → deny (fail-closed, никогда не expose по опечатке).
- [ ] Стандартные пресеты как явная owner-UI-настройка (фронт, RB2-хвост).
- [ ] Богаче safety-bounds валидатора (напр. предупреждать, когда «продвинутая» политика молча даёт
      public) — сейчас только well-formed.

### GDPR-erasure (§7.5 право на забвение) — ✅ MVP DONE 2026-07-04
- [x] `POST /subjects/erase {id}` (cabinet, owner tenant-guarded) → `gdprEraseSubject`: hard-delete
      всех удаляемых PII-записей (`cascadeDeleteSubject`: knowledge/заметки, episodes, payments,
      identities, edges, expectations, promises) + **редакция** PII в append-only опыт-логе
      (`scrubEventsFor`: `putT` перезаписывает `eePayload`/`eeEmotion` → `[erased]`, сохраняя структуру
      события — id/subject/timestamp/type — для аудита/счётчиков; `delT` на eventsT запрещён, `putT` — нет).
      Smoke: до — knowledge=1/events=1; A erase→200 (B→404 owner-guard); после — knowledge `[]`, events=1
      (append-only сохранён), субъект удалён.
- **АУДИТ (2026-07-04) — находка A (medium) ИСПРАВЛЕНА:** `cascadeDeleteSubject` НЕ удалял
      **appointments** (`deleteEpisodeDeep` каскадит только transitions/deviations, не appointments; и
      standalone-брони вообще мимо) → времена/длительности сессий (PII) оставались. Добавил
      `byIndexT appointmentsT apptBySubject → delT`. Verified: appointments до erase=1, после=0. Чинит и
      `/subjects/delete`. Evidence — уже ок (`deleteKnowledgeDeep` каскадит). **Остаток (low):** outbox-
      записи (`obTo` email + body) субъекта не стираются (транзитная очередь); eeCounterpart-события (где
      субъект — вторая сторона чужого peer-события) не редактируются (это запись ДРУГОГО субъекта).
- **ЧЕСТНЫЙ предел (задокументирован + продемонстрирован в smoke):** редакция стирает ТЕКУЩЕЕ состояние
      и ВСЕ application-чтения, но **WAL-файл хранит исходные op** (grep WAL → и `EVENT_PII_888`, и
      `[erased]`). Полное стирание = WAL-компакция ИЛИ crypto-shred (шифровать PII + удалить ключ) —
      follow-up (крупная арх.-фича); пока WAL держать зашифрованным at-rest.

### RB4 audit-bot — ✅ MVP DONE 2026-07-04
- **Чанк = ОДИН владелец (tenant) за тик** — единица rate-limit. Обоснование: конфиг доступа владельца
  (identities/visibility/policies) самодостаточен; аудит одного = ограниченное чтение его подмножества,
  быстрый тик, малый спайк; пауза между владельцами размазывает нагрузку; стор — in-memory `readBase`-
  snapshot → тик НЕ держит блокировку, между тиками свободно идут клиентские запросы.
- **Курсор бесстейтовый:** `Cxm.Api.auditPick unvMax pauseSec now b` → `(now / (1+pauseSec)) % numTenants`
  → аудит tenant[idx]. Крупного владельца потом суб-чанк.
- **АУДИТ RB4 (2026-07-04) — находка A (medium/high) ИСПРАВЛЕНА:** первый курсор был `now % numTenants`.
  `now` растёт на ~pauseSec за тик → индекс сдвигается на `pauseSec mod numTenants` → **ЗАСТРЕВАЕТ**, когда
  `gcd(pauseSec, numTenants) > 1` (частый случай при круглом pauseSec: 60с/50 тенантов → аудируются
  лишь 5, остальные 45 — НИКОГДА). Repro: pauseSec=4, 3 владельца сверх порога → флагнут ТОЛЬКО 1 (owner 2),
  двое молча пропущены. Фикс: делим на `1+pauseSec` → курсор = номер ТИКА (растёт на 0/1 за тик, `now`<делителя)
  → сдвиг ≤1 → обходит ВСЕХ без пропусков. Verified: pauseSec=2, тот же сценарий → флагнуты все 3 (owner 2/12/22).
  **Находка B (low) ИСПРАВЛЕНА (доработка 2026-07-04):** был полный `tscan identitiesT`+фильтр (O(всех
  identity) за тик). Колонка `tenant` в `identitySchema` УЖЕ была (`mkCol`) → сменил на `idxCol` (индекс 1
  byTenant) — БЕЗ миграции (та же кодировка/колонки, вторичный индекс строится из строк при загрузке).
  `identByTenant=1` в Store.Base; `auditTenant` теперь `tbyIndex identitiesT identByTenant ten` → чтение
  O(identity ОДНОГО владельца) = настоящий bounded-чанк. Verified: owner 2→3, owner 6→4 (верные пер-тенант
  счётчики, без утечки). **Находка C (low/шум) ИСПРАВЛЕНА:** IORef `auditRef : List (ℕ×String)` держит
  последний залогированный fingerprint на владельца; `Cxm.Api.auditStep prev ten fs → (state', linesToLog)`
  логирует finding ОДИН раз, ре-логирует лишь при ИЗМЕНЕНИИ текста. Single-thread (только эта петля) → простой
  IORef. Verified: стабильный finding — 1× за 7с (было ~3-7×); drA 3→4 → ре-лог 1× с новым счётчиком.
- **Проверка (MVP):** `auditTenant` считает НЕподтверждённые identity владельца; `> CXM_AUDIT_UNVERIFIED_MAX`
  (деф 5) → finding «possible spam-prep» (стыкуется с P1b email-verification). Точка расширения — там же.
- **Цикл (CxmServer):** отдельный `forkLoopEvery CXM_AUDIT_PAUSE_SEC` (деф 0 = ВЫКЛ), каждый тик
  `readBase → auditPick → emitAudit` (лог `[audit] …`; ops/SIEM ловит). Отдельная, более медленная петля
  от maintenance-воркера (`CXM_WORKER_SEC`).
- **Smoke:** drA 3 неподтв. (>2) → `[audit] owner 2: 3 unverified …` залогировано **3× за 8с** (НЕ каждый
  тик — доказывает per-owner чанкинг: owner всплывает раз в ~numTenants тиков); drB 1 (≤2) — НЕ флагнут.
- **ДОДЕЛАНО 2026-07-04 (мульти-проверки + отчёт-канал):**
  - **Проверка 2:** `checkLiveTokens` — владелец с `> CXM_AUDIT_TOKENS_MAX` (деф 10) ЖИВЫХ (не отозванных)
    integration-токенов → «oversized /v1 attack surface». `auditTenant` теперь `check1 ++ check2`
    (расширяемо: добавить проверку = `++`). Токены читаются через НОВЫЙ индекс `intTokenByTenant`
    (`intTokenSchema` `tenant` `mkCol`→`idxCol`, БЕЗ миграции) → bounded, как identity.
  - **Отчёт-канал:** `CXM_AUDIT_REPORT_TO` (""=только-лог; адрес=слать). При ИЗМЕНЁННЫХ findings
    `reportAudit` кладёт в outbox notification (`enqueueNotification "email" reportTo …`) → воркер
    доставляет. Пьёт из dedup C → без спама. Verified: 3 токена → лог `owner 4: 3 live …` (1×) +
    admin GET /outbox = 1 pending к `ops@example.com`.
  - **Остаток (не критично):** ещё проверки (public-ресурс на приватном якоре, аномально широкая
    policy); суб-чанк по ресурсам для крупного владельца; отчёт-таблица + GET /audit/report.

### RB4 [advisory / мониторинг] — исходная идея (идея пользователя, 2026-07-04)
- [ ] Периодический бот (на воркер-инфре `Cxm.Worker`/reminders) проходит по пользователям/ресурсам
      и **сообщает о подозрительных** конфигурациях доступа (не блокирует — advisory, human-in-loop):
      напр. «приватно-выглядящий контент помечен public», необычно широкий allow, пустой blocklist,
      политика противоречит дефолтам владельца. Отчёт в outbox/mentions. Третий слой ограждений:
      write-time валидатор (жёстко) + load-time platform-guardrail (жёстко) + **audit-бот (мягко)**.

### RB3 [слой 3] — пределы как инварианты — ✅ ПОЛ ПРИВАТНОСТИ satisfied-by-construction
- [x] **Пол приватности кабинета уже enforced ТИПОМ + скоупингом:** `canAccess : … → Resource → Bool`
      принимает ТОЛЬКО `Resource` (контент). Кабинетные типы (`Knowledge`/`Episode`/`Appointment`/
      `Expectation`) НЕЛЬЗЯ прогнать через content-policy (type error) — их чтения идут напрямую через
      tenant-скоуп (аудит #1/#3). Т.е. владелец физически не может «сделать заметку о клиенте public».
- [ ] (низкий приоритет, формализация) явная маска `owner-policy ∧ floor` для контента — контент
      кросс-тенант by design, floor там = author-check + fail-closed (уже есть); типизировать позже.

### P1/P2 SECURITY (2026-07-04) — ✅ DONE
- [x] **P1a — класс `public` + классификатор:** `rbacAuthz` берёт `classify : method→path→Maybe Perm`
      (`nothing`=public→allow); `CxmServer.classify` = core `pathPerm` + пак-public (`/psych/offerings`,
      `/psych/availability` — каталог+слоты). Ядро вертикаль НЕ называет. Smoke: anon→pack-reads 200,
      кабинет 403. **Реклассификация:** `/integration-tokens` (mint/list — свои, tenant-scoped) → cabinet
      (owner self-service), НЕ admin (иначе owner не может выпустить свой /v1-токен).
- [x] **P1b — `/notifications` tenant-scoping:** owner шлёт только на identity своего тенанта (iTenant≡ct),
      иначе 403 (спам-вектор закрыт). Внутренние reminders (worker) не тронуты. Smoke ✓.
- [x] **P2a — v1-ingest-tenant:** `postV1Events` резолвит integration-token → `itkTenant` (`v1Tenant`),
      штампует событие тенантом ВЛАДЕЛЬЦА (не defaultTenant). Smoke: ingest по токену A → лог A, B пусто.
- [x] **Хвосты owner-guard ✅ DONE 2026-07-04:** `/integration-tokens/revoke` + `/subjects/delete` →
      cabinet (убраны из privPaths); `revokeIntegrationToken`/`cascadeDeleteSubject` берут `caller` и
      гардят `itkTenant/sTenant ≡ caller` → `Forbidden`. Smoke: B revoke/delete A→403; A свои→200;
      anon→403. Owner self-service закрыт.
- **Остаток:** прочие `/v1/*` writes (publish/comment) штампуют defaultTenant (атрибуция как P2a, если
      надо); email-verification для честного закрытия P1b (#1 из аудита).

### АУДИТ owner-guard-хвостов (2026-07-04)
- **Гарды revoke/delete — корректны:** guard ДО каскада; каскад трогает только своё-тенантные записи
  субъекта (edges/identities/entitlements/episodes/knowledge/expectations/promises/payments); опыт-
  события НЕ удаляются (append-only §8.2 by design → subject-delete частичен, PII событий остаётся —
  это GDPR-erasure P3, не дефект хвостов). Не обходятся (caller — серверный JWT→uTenant).
- **НАЙДЕНО+ИСПРАВЛЕНО — existence oracle (систем., усиливает finding #1):** ВСЕ 11 tenant-гардов делали
  `requireT … NotFound` (существование) ЗАТЕМ `guardT … Forbidden` → чужой id давал **403 (есть)** vs
  **404 (нет)** → перебор sequential id (масштаб платформы / счётчики чужих объектов). Заменил
  `Forbidden`→`NotFound` в 11 tenant-гардах (2 content-author-гарда — не трогал, контент не секрет).
  Verified: B на чужой существующий субъект → **404**, на несуществующий → **404** (неотличимо), свой → 200.

### АУДИТ P0/P1/P2 (2026-07-04)
- **#2 (CXM_DEV footgun) — ИСПРАВЛЕНО:** было `devMode = not (null dev)` → любой непустой `CXM_DEV`
  (вкл. `false`/`0`) отключал boot-guard. Стало `dev ∈ {"1","true"}`, иначе guard активен (fail-safe).
  Verified: `CXM_DEV=false`+дефолт-секрет → FATAL; `CXM_DEV=1` → служит.
- **#1 (P1b) — ✅ ЗАКРЫТО ПО-НАСТОЯЩЕМУ 2026-07-04 (email-verification / double-opt-in):**
  `postBindIdentity` создаёт identity `verified=false` (вызывающий больше НЕ задаёт verified) и шлёт
  на адрес через ЕГО канал одноразовый токен `hmacSHA256(secret, "verify-identity:"++channel++":"++id)`.
  Публичный `POST /verify-identity {channel,id,token}` (в routeExt, до authz) сверяет HMAC → команда
  `verifyIdentities` ставит `iVerified=true`. `/notifications` `ownedTo` теперь требует `iVerified`.
  Канало-generic (email сейчас; telegram/SMS позже — только другой delivery-адаптер, токен/verify те же).
  Smoke: bind→unverified→notify **403**; wrong token **403**; correct token **200**; verified→notify **200**.
  **АУДИТ реализации (2026-07-04) — 2 находки, ИСПРАВЛЕНЫ:** (B, medium) `verifyIdentities` ставил
  verified для ВСЕХ identity с (channel,ext) по всем тенантам → verify владельцем A включал биндинг B
  того же адреса (нотификации без согласия получателя для B); (A, low) сообщение токена
  `…:++ch++":"++ext` — delimiter-ambiguity. Оба закрыты: токен + verify стали **per-identity-id**
  (`hmac(secret,"verify-identity:"++show id)`, `verifyIdentity iid` через `requireT`), `/verify-identity
  {identity,token}`. Smoke (два владельца, один email): A verify → A notify 200, **B notify 403**
  (не авто-verified), B-токен не верифицирует A-identity; B отдельно verify → B notify 200.
  **Остаток (low):** verification-письмо шлётся на любой адрес per-bind (фикс-контент, ограничено) →
  rate-limit на edge; недоставляемые каналы (cookie/user_id) плодят мёртвые outbox-записи.
- ~~#1 (P1b обходится)~~ было: `bindIdentity` берёт `verified` от вызывающего и НЕ
  проверяет владение email; `ownedTo` не требует `iVerified`. → owner привязывает ЛЮБОЙ email к своему
  субъекту и шлёт. P1b = частичное смягчение (auditable, owner-attributed, лишний шаг), НЕ закрытие.
  **Настоящий фикс = email-verification flow (double-opt-in), `verified` не задаётся вызывающим** —
  отдельная фича. Требовать `iVerified` сейчас нельзя — сломает легит-нотификации (identities по
  умолчанию unverified). Ляжет в RB4/audit-бот («owner привязал много внешних email») + verification.
- **Мелкие (не дефекты):** `publicSafe` проверяет только роль `anon` (кастомные public-роли деплоя не
  ловит); `classify` method-нечувствителен для public-путей (безвредно, 404); `v1Tenant` fallback —
  мёртвый код (токен всегда есть после гейта). Остальное P0/P1/P2 — корректно.

## Границы
- Роли/перма/пределы — конфиг (принцип 9), но с fail-closed дефолтами.
- Ядро остаётся нейтральным: `cabinet`/`admin`/`owner`/`anon` — нейтральные слова (не вертикаль).
- См. [[cxm-community-isolation]] (data-scoping + аудит), [[cxm-frontend-layering]].
