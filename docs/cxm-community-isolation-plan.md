# CXM community: один сайт — много психологов — owner-изоляция кабинета

> **Статус:** план (2026-07-03). Модель зафиксирована пользователем: **один общий инстанс, много
> психологов как полноценные пользователи, большое сообщество**; приватный кабинет каждого —
> изолирован. Конвенции исполнения — как в кабинет-плане (typecheck на модуль, стражи, refl,
> rebuild+cabal, live-smoke, аудит с адверсариями).

## Модель (не переигрывать)

- **tenant = психолог (владелец).** `User.uTenant` УЖЕ есть; `uLogin` = principal из JWT (`sub`).
  Значит **без миграции схемы** — tenant-поле на КАЖДОЙ записи ([ВХ]/[СОБ]), нужно лишь протянуть
  tenant вызывающего в кабинетные команды и фильтровать чтения.
- **Кабинет приватен** (Knowledge/Subject/Episode/Appointment/Expectation/Evidence о клиентах) →
  скоуп по tenant вызывающего. Клиент-субъект принадлежит tenant'у своего психолога.
- **Соц/контент — кросс-тенант, shared** (Resource/Offering/comments/feed/`/v1/*`) → НЕ фильтруется
  по tenant; доступ по author + visibility (public/followers/entitled) как сейчас. Две модели
  уживаются — это разные таблицы/пути чтения.
- **Предположение (поправь, если не так):** клиенты — субъекты во владении психолога, НЕ отдельные
  аккаунты. Клиент общается через `/v1/*` (integration-token) или как участник сообщества. Аккаунты
  клиентов ("в полный рост") — если нужны, это доп-объём (регистрация client-user), НЕ в фундаменте.

## Фаза И — Owner-изоляция кабинета

- [ ] **И1. Резолвер tenant вызывающего** (Api): `callerTenant secret req b : IO TenantId` =
      `resolvePrincipal → login → findUserByLoginIn → uTenant`; fallback `defaultTenant`
      (аноним/loopback/token""). ✅ СДЕЛАНО (фундамент).
- [ ] **И2. Регистрация психолога = tenant + user** (Commands `registerPsychologist` →
      создать `Tenant` + `User(uTenant=new)`, вернуть tenant id) + роут `POST /auth/register
      {login,password,name}`. ✅ СДЕЛАНО (фундамент). Первый оператор/seed = defaultTenant.
- [x] **И3. Протяжка tenant в `dispatch` → кабинетные хендлеры.** `routeExt` резолвит `callerTenant`
      (secret+base) и передаёт `dispatch ct h req`; кабинетные хендлеры берут `ct : TenantId`
      первым аргументом; не-кабинетные — без изменений.
- [x] **И4. Стемпинг tenant'ом вызывающего** (вместо `defaultTenant`) на кабинетных write:
      createSubject, createKnowledge, updateKnowledge(+гард `kTenant≡caller`→Forbidden),
      attachEvidence(+гард), createExpectation, bookAppointment, createEpisode, createProtocol,
      addEdge, bindIdentity.
- [x] **И5. Скоуп чтений по tenant** на кабинетных роутах: `/knowledge|episodes|appointments|
      experience-events|expectations|edges/by-subject`, `/profile`, `/lines`, `/decision-unit`,
      `/relationship-state/by-subject`, GET `/subjects|episodes|appointments|experience-events|
      edges|identities`. Фильтр subject AND `tenant≡caller`; чужой subject → пусто.
- [x] **И6. Соц/контент кросс-тенант** — `/resources`·`/offerings`·`/v1/*` НЕ трогали; проверено:
      B видит публичный пост A через `GET /resources` (visibility-gated), т.е. shared community.
- **DoD:** ✅ адверсарный live-smoke: A→tenant2, B→tenant4; B не видит знания/клиентов/identity A
      (пусто), не может обновить знание A (`forbidden`); A видит своё; соц-пост A виден B. Gen+cabal+
      neutrality зелёные.

### И7 — остаточные операторские листинги ✅ DONE 2026-07-03
- [x] Скоуп по tenant: GET `/accounts`,`/promises`,`/payments`,`/assignments`,`/integration-tokens`;
      write-стемпинг `assignRole`/`createIntegrationToken` берут `ct`. `/resources|offerings|
      resource-links|v1/*` — ОСТАВЛЕНЫ кросс-тенант (community by design; проверено).
- [x] Smoke: A минтит int-token → A видит, B пусто. B не может сменить статус ожидания A (forbidden).
- **Остаётся мелочь (низкий приоритет):** GET `/outbox`,`/events` (bus) — системная инфраструктура,
      не client-private, пока кросс-тенант. И `/v1/*` ingest стемпит `defaultTenant`, а не владельца
      по integration-token (нужен `tokenTenantIn` через v1-гейт) — но операторский лог касания (Д1)
      уже owner-scoped, так что лента опыта наполняется изолированно с операторской стороны.

## Фаза Д — добивка «надо не очень» ✅ DONE 2026-07-03 (кроме Д4)
- [x] **Д1 (#1):** `POST /experience-events` (operator) — лог касания клиента (subject/type/sentiment/
      effort/isPeak/isEnd/episode/payload), channel=Internal, actor=Staff, owner-стемплено. Smoke ✓.
- [x] **Д2 (#2):** `POST /expectations/status {id,status}` → `setExpectationStatus` (+гард `xpTenant≡caller`
      →Forbidden). Статус met/unmet виден в `/expectations/by-subject` — это gap-сигнал слоя II.
      (Численный gap «восприятие−ожидание» — позже, нужна метрика «восприятия».)
- [x] **Д3 (#3):** `POST /knowledge/evidence/by-knowledge` — цепочка доказательств знания
      (index `evdByKnowledge`, фильтр `evdTenant≡ct`). Smoke ✓.
- [x] **Д5 (#5):** decay-at-read — `applyDecay now` в `/knowledge/by-subject` и
      `/relationship-state/by-subject` (FACT decay=0 не убывает). Wired ✓.
- [ ] **Д4 (#4) ОТЛОЖЕНО:** авто-`conflictSignal` (STATED↔OBSERVED) требует ключа-претензии для
      детекции конфликта (kDetail — opaque, семантически не сравнить). `conflictSignal`(400‰) — есть
      константа; авто-подключение отложено до дизайна claim-key. Не блокер.

## Фаза Д — добивка «надо не очень» (строится СРАЗУ owner-scoped, после Фазы И)

- [ ] Д1 (#1): `POST /experience-events` (operator) — ручной лог касания клиента
      (subject/type/sentiment/effort/isPeak/episode) в ленту опыта.
- [ ] Д2 (#2): роут `setExpectationStatus` + gap-read «восприятие − ожидание» (суть слоя II).
- [ ] Д3 (#3): evidence-read (`/knowledge/evidence/by-knowledge`) — объяснимость.
- [ ] Д4 (#4): подключить `conflictSignal` (STATED↔OBSERVED) на записи знания.
- [ ] Д5 (#5): decay-at-read — `decayedConfidence(now)` в кабинетных энкодерах.
- **#7 (доп. правила инференса):** по нужде, не впрок.

## Границы
- Соц-часть (Р1) не трогаем — она кросс-тенант by design.
- Промисы (Р4), выделенный DM/circles (Р5) — вне scope.
- Фронт: `agdelte → cxm-ui → сайты` ([[cxm-frontend-layering]]); не ядро.
