> **★ ОБНОВЛЕНО 2026-07-07 — стор: Postgres-only.** WAL + in-memory движок УДАЛЁН (движок и старые
> WAL-команды снесены; сервер — `cxm-server-pg` на живом PG). Любые упоминания WAL / memory-image /
> «ждёт драйвера» / «Postgres отложен» НИЖЕ — ИСТОРИЯ. Актуальная модель хранения, статус и контракты:
> **`docs/pg-store-plan.md`**.

# agdelte-cxm — план реализации

> **Статус:** план. Исполняется по фазам; отмечай пункты `- [x]` по мере готовности.
> По запросу пользователя выполненные пункты можно удалять.
> **Источник истины по дизайну:** `~/cxm-core/docs/cxm-description.md` (далее «Описание», ссылки
> §N). **Концепция:** `~/cxm-core/docs/CXM-концепция-и-ядро.md` («Ч2 §3»).
> **Референс-код (не менять, только читать):** `~/.agda/agdelte-crm/` (паттерн модулей),
> `~/agdelte-addons/agdelte-store/` (IndexedMap/WAL/Txn/Schema), `~/.agda/agdelte-pack-psych/`
> (что переносим), `~/.agda/agdelte-courses/` (frozen, референс курсов).

---

## Как пользоваться планом (важно после `/clear`)

1. Читать **строго по порядку фаз** — они в порядке зависимостей.
2. Перед началом фазы прочитать соответствующие § Описания (указаны в фазе).
3. **Definition of Done каждой фазы:** все её модули **проходят typecheck** и **тесты
   зелёные**. Не переходить к следующей фазе с красным.
4. **Typecheck модуля:** `agda <путь>.agda` (библиотеки зарегистрированы в
   `~/.agda/libraries`; `agdelte-cxm` добавляется в Фазе 0). Проверять каждый модуль
   сразу после написания.
5. Соглашения кода — раздел «Конвенции» ниже. Не отступать от них.
6. Ничего в `agdelte-crm`/`agdelte-store`/`agdelte`/`agdelte-auth`/`agdelte-payments`
   **не меняем** до Фазы 11 (перенос), кроме регистрации библиотеки.

---

## Решения по развилкам (§9 Описания) — ЗАФИКСИРОВАНЫ

Исполнителю НЕ переигрывать; если решение мешает — остановиться и спросить.

- **§9.1 Перенос CRM → «сразу переформулировать».** Party/Engagement/Participation
  выражаем через `Subject`/`Episode`/`SubjectEdge` с самого начала (принцип 7 «один путь
  кода»; два словаря запрещены). Цена — неавтоматический переезд pack-psych (Фаза 11 =
  приёмочный тест).
- **§9.2 Три лога.** `ExperienceEvent` — своя append-only таблица (истина). Доменная шина
  `Event` + `Outbox` — отдельные узкие таблицы. op-log WAL — под всем, из `agdelte-store`.
- **§9.3 Персистентность → WAL+память сначала.** Postgres отложен, НО за repository-seam
  (принцип 11), чтобы стать второй реализацией. Seam — обязателен с Фазы 5.
- **§9.4 Миграции (мин. в первый заход):** версия схемы на сущность + хук event-upcasting
  + сохранить Tier-1 tolerant-decode. `ALTER`-diff отложен.
- **§9.5 `CxmOp`** — по `Set/Del` на сущность (как CRM), сгруппированы по модулям; `Op` —
  **внутренняя деталь WAL-бэкенда** за store-интерфейсом, не доменное API.
- **§9.6 Расписание → в ядро.** Generic `Cxm.Schedule` (availability + slot-conflict);
  pack даёт лишь календарь-конфиг.
- **§9.7 Числа.** Фикс-точка ℕ: `confidence`/`decay` = промилле (0..1000). `sentiment`
  хранить с офсетом: `(−1..1)` → ℕ `0..2000` (индексируемо через `keyOf`). `Account`
  одновалютный ℕ на MVP (валюта отложена).
- **§9.8 tenant.** `TenantId = ℕ`, FK на запись `Tenant`; дефолтный tenant засевается
  (single-operator). Поле `tenant` на каждой [ВХ]/[СОБ] сущности.
- **§9.9 Изоляция инстансов → DB/WAL-на-инстанс** (реализация — Фаза 12/отложено; ядро
  лишь берёт storage-handle из конфига).
- **§9.10 Активация packs конфигом** — все packs в бинаре, конфиг включает подмножество;
  единый `Base`/`CxmOp`, неактивные packs = пустые карты. Реализация гейтинга — Фаза 12.

---

## Конвенции (следовать во всех модулях)

- **Модуль проектируется ВМЕСТЕ со спецификацией** (введено 2026-07-02): шапка-комментарий файла
  = полная спека (назначение/§§/инварианты/запреты); строка в `docs/MODULES.md` = сводная; границы
  слоёв enforced `scripts/check-layering.sh` (G1–G5) — держать зелёным наравне с нейтральностью.
  Чек-листы изменений (новый модуль/поле/команда/enum) — `docs/MODULES.md` §5.
- [ ] `{-# OPTIONS --without-K #-}` в каждом модуле; `--guardedness` только где IO (Api).
- Паттерн модулей как в CRM: **records-only** (`Cxm.*.Identity`-подобные) отдельно от
  store/ops/queries.
- **Время — из IO:** `now : ℕ` приходит параметром команд/проекций (#N2 CRM). Ядро часов
  не читает. `decay`/валидность/окна — от переданного `now`.
- **Один источник схемы:** `Agdelte.Storage.Schema` → из одной `Schema` и Wire-кодек, и
  индексы (`imIndexes`), и SQL DDL. Не писать ручных экстракторов индексов.
- **Коллекционные поля → дочерние таблицы** (Schema атомарно-колоночная): `evidence`,
  `transition_log`, `deviations`, `states`/`transitions`, граф `DecisionUnit` — отдельные
  записи (как `Participation`→`SubjectEdge`). См. Описание §8.1.
- **Корректность по построению, где дёшево:** денежный инвариант (баланс ≥ 0) proof-gated
  (как CRM `charge`); никаких `postulate`/`primTrustMe`/`TERMINATING` в доменной логике.
- **Принцип 11:** доменные команды/проекции ходят через store-интерфейс, НЕ дёргают
  `IndexedMap` напрямую.
- **Принцип 12:** никаких module-level мутабельных глобалов; всё, что нужно инстансу, —
  параметр конфига.
- **tenant** — поле на каждой релевантной сущности, дефолт-значение схлопывает до
  single-operator.
- Round-trip кодека обязателен: `decode (encode x) ≡ just x` (тест на сущность).

---

## Фаза 0 — Каркас библиотеки

Читать: Описание §0, §1, §8.1. Референс: `agdelte-crm/*.agda-lib`, `ServicesCore.agda`.

- [x] Создать каталог `~/.agda/agdelte-cxm/` со структурой `Cxm/`.
- [x] `agdelte-cxm.agda-lib`: `name: agdelte-cxm`; `include: .`; `depend: standard-library
      agdelte agdelte-store agdelte-auth agdelte-payments`.
- [x] Зарегистрировать путь в `~/.agda/libraries` (добавить строку).
- [x] `README.md` — краткое назначение + ссылка на `cxm-description.md`.
- [x] Скопировать/адаптировать `scripts/check-neutrality.sh` (ядро не должно называть
      вертикали: `psych|vet|курс|clown|медцентр`).
- [x] Umbrella-модуль `Cxm/All.agda` (импортирует всё; служит целью typecheck) — наполнять
      по мере фаз.
- **DoD:** пустой `Cxm/All.agda` (или с заглушкой) проходит `agda`.

---

## Фаза 1 — Фундамент: конфиг, числа, эпистемический конверт, tenant

Читать: Описание §4.1, §2 (принципы 7,9,11,12), §9.7, §9.8.

- [x] `Cxm/Num.agda` — фикс-точка ℕ: тип/алиасы `Permille` (0..1000) для confidence/decay;
      кодирование `sentiment` со офсетом (−1..1 → 0..2000); хелперы клампа/арифметики.
- [x] `Cxm/Config.agda` — тип `InstanceConfig` (эскиз): storage-handle-параметры (путь
      WAL и т.п.), список активных packs (ℕ/строки), tenant-политика, seed-данные. Реализует
      принцип 12 (ядро = функция конфига). Пока — тип + конструкторы, без чтения глобалов.
- [x] `Cxm/Tenant.agda` — `TenantId = ℕ`; запись `Tenant`; дефолтный `TenantId` (напр. 1).
- [x] `Cxm/Knowledge.agda` — эпистемический конверт: enum `EpistemicType`
      (FACT/HYPOTHESIS/STATE/TRAIT), `Source` (OBSERVED/INFERRED/STATED/IMPORTED),
      `KStatus` (ACTIVE/CONFIRMED/REFUTED/SUPERSEDED); запись `Knowledge` (subject_id,
      тип, source, confidence:Permille, valid_from/to, decay, status; `evidence` — НЕ поле,
      дочерняя таблица, Фаза 4). **Smart-конструкторы с инвариантами:** `FACT ⇒ conf=1000`;
      `INFERRED ⇒ conf<1000` (evidence≠∅ проверяется на уровне команды приёма, Фаза 8/9).
- **DoD:** модули typecheck; юнит-тест на офсет sentiment (round-trip) и на smart-конструкторы. ✅

---

## Фаза 2 — Субъект, граф, идентичность

Читать: Описание §4.2, §4.3, §4.4 (вкл. провизорный субъект + `merge`-алиас).

- [x] `Cxm/Subject.agda` — запись `Subject`: `id`, `kind` (EXTERNAL|INTERNAL),
      `structure` (Person|Account), `display_name`, `tz`, `created_at`, `deleted_at`,
      `tenant`, `serves` (Maybe — для INTERNAL), `canonical` (Maybe id — алиас для
      слитого/провизорного; nothing = сам канонический), `provisional` (Bool).
- [x] `Cxm/Edge.agda` — `SubjectEdge`: `id`, `from`, `to`, `kind` (participation|membership|
      decision_consult|owner|patient|follow|…), `role` (Maybe), `ordinal` (для упорядоч.
      графа консультаций), `valid_from/to`, `tenant`, `created_at`.
- [x] `Cxm/Identity.agda` — запись `Identity`: `id`, `subject_id`, `channel`, `external_id`,
      `verified`, `tenant`, `created_at`. (Стратегия матчинга — НЕ здесь, хук на краю.)
- **DoD:** typecheck; ADR-комментарий в `Subject` про алиас-механику `merge` (события не
  переписываются — §4.4). ✅

---

## Фаза 3 — События: `ExperienceEvent` [СОБ] + шина/outbox

Читать: Описание §4.5, §4.15, §8.2 (три лога). Референс: CRM `Event`/`OutboxEntry`.

- [x] `Cxm/Event.agda` — `ExperienceEvent` (канонический конверт §4.5): `event_id`,
      `subject_id`, `tenant`, `channel` (enum: WEB/MOBILE/CHAT/EMAIL/PHONE/PRODUCT/INTERNAL/…),
      `actor` (enum), `timestamp`, `type` (enum вкл. VIEW/PURCHASE/TICKET_OPEN/FEATURE_USE/
      FEATURE_REQUEST/INTERNAL_HANDOFF/…), `lifecycle_stage`, `episode_id` (Maybe),
      `sentiment`/`emotion`/`effort` (Maybe), `is_peak`/`is_end` (Bool), `payload` (String
      JSON). Append-only — нет `Del`-семантики на уровне домена.
- [x] `Cxm/Bus.agda` — доменная шина `Event{topic,payload,processed}` + `OutboxEntry`
      (durable-интент уведомления). Перенести из CRM как есть, добавить `tenant`.
- **DoD:** typecheck; тест: событие с/без опциональных аннотаций. ✅

---

## Фаза 4 — Схемы/кодеки для всех записей + дочерние таблицы коллекций

Читать: Описание §8.1 (коллекции→дочерние таблицы). Референс: `Crm/Wire.agda`.

- [x] `Cxm/Wire.agda` — для КАЖДОЙ записи Фаз 1–3 и будущих 6: `xSchema` (со всеми тремя
      интерпретациями), `xToRow`/`xFromRow`, `encX`/`decX`. Индексируемые колонки помечать
      `idxCol` (см. запросы фаз 6–8). (Записи Фазы 6 дописываются сюда при их появлении.)
- [x] Дочерние-таблицы для коллекций как отдельные записи+схемы: `Evidence`
      (knowledge_id, event_id), `Transition` (episode_id, from_state, to_state, at, ordinal),
      `Deviation` (episode_id, kind, at), `ProtocolState`/`ProtocolTransition`
      (protocol_id, …). `SubjectEdge` уже покрывает граф `DecisionUnit`.
- [x] Enum-кодеки (channel/actor/type/kind/status/…) — как `encActStatus` в CRM.
- **DoD:** typecheck; **round-trip тест** на каждую запись: `decX (encX x) ≡ just x`. ✅

---

## Фаза 5 — Стор: repository-seam + WAL-бэкенд + Txn

Читать: Описание §8.1, §8.3, §8.7 (принцип 11). Референс: `Crm/Store.agda`, `Crm/Txn.agda`,
`Agdelte.Storage.Txn`.

- [x] `Cxm/Store/Interface.agda` — **backend-agnostic интерфейс** (принцип 11): `Table V`
      (параметризованный handle) + операции `getT`/`putT`/`byIndexT`/`scanT`/`requireT`/
      `delT`/`freshId`; типы полей `Table` не упоминают `IndexedMap`. Доменные команды пишутся
      ТОЛЬКО против него. `commitTxn` (IO) — в `Store/Wal`.
- [x] `Cxm/Store/Base.agda` — `Base` = `IndexedMap` на каждую сущность (вкл. дочерние
      таблицы Фазы 4) + `nextId`; `CxmOp` (Set/Del на сущность, §9.5); `apply` (индексы
      через IndexedMap, `bump nextId`); `Err`; `emptyBase` (через `imIndexes … schema toRow`).
      **Инвариант (из аудита #2):** `nextId` начинается с **1** — `0` зарезервирован как
      «none» для optional-FK (`Wire.fkOrZero`/`zeroToNothing`: `episode`, `canonical`).
- [x] `Cxm/Store/Codec.agda` — `encodeOp`/`decodeOp` (тегированный, как CRM #D).
- [x] `Cxm/Store/Wal.agda` — реализация `Store.Interface` поверх `agdelte-store` WAL
      (`WalConfig`/`walTxn`/`walRead`; `openStore`/`readBase`/`commitTxn`). `CxmOp` здесь —
      внутренняя деталь. `--guardedness` (IO) → отдельная umbrella `Cxm/AllIO.agda`.
- [x] `Cxm/Txn.agda` — инстанс `Agdelte.Storage.Txn Base CxmOp Err apply` (re-export).
- **DoD:** typecheck; тест: `runTxn` round-trip + реплей лога (encode→decode→apply) восстанавливает
      Base; op-codec round-trip на все 26 `CxmOp`; `nextId`. Чтения через seam — в runtime-харнессе
      (NatMap.lookup не редуцируется под `refl`, как и в CRM). ✅

---

## Фаза 6 — Доменные примитивы-истина [ВХ] + команды

Читать: Описание §4.9–4.15, §9.6. Референс: `Crm/Commands.agda` (create/guards/cascade).

> **Раскладка (вынужденная ацикличностью схемо-стора):** записи — в record-only модулях
> `Cxm/Offering|Resource|Entitlement|Account|Payment|Expectation|Protocol|Episode|Users.agda`
> (Wire→запись, Base→Wire, команда→Base — иначе цикл; так же CRM делит `Identity`/`Commands`).
> Команды — единый слой `Cxm/Commands.agda` на seam (как `Crm.Commands`). `Cxm/Schedule.agda` —
> чистый core-примитив (без стора).
- [x] `Cxm/Offering.agda`, `Cxm/Resource.agda`, `Cxm/Entitlement.agda` — записи; команды
      (create/update/soft-delete) в `Cxm/Commands.agda`. `Resource` — дерево (`parent_ref`,
      индексируем через 0-сентинел), `visibility_policy` непрозрачный. `Entitlement.target` =
      offering|resource|membership (enum `EntTarget`).
- [x] `Account` (`Cxm/Account.agda`) + `charge` **proof-gated** (`debit : amt ≤ bal → ℕ`,
      `yes pf`/`no→abort Insufficient`), `credit`, `openAccount` — в `Cxm/Commands.agda`.
- [x] `Cxm/Payment.agda` — `Payment` (pending→succeeded/failed); `recordPayment`,
      `findPaymentByExtId` (scan), `markPaymentSucceeded` → грант `Entitlement` (TOffering).
- [x] `Cxm/Expectation.agda` — `Expectation`/`Promise` пара; команды create/status/fulfil/break.
- [x] `Cxm/Protocol.agda` (states/transitions — дочерние) + `Cxm/Episode.agda` (скелет);
      `transitionEpisode` пишет `Transition` + append-only `ExperienceEvent` (новый тип
      `LifecycleChange`), проверяет допустимость перехода по `ProtocolTransition`.
- [x] `Cxm/Schedule.agda` — **generic availability + slot-conflict** (§9.6): чистые
      `overlapsᵇ`/`slotFree`/`grid`/`freeSlots`; pack подаёт календарь-конфиг. Обезличено.
- [x] Команды субъекта (в `Cxm/Commands.agda`): `createSubject`, `addEdge` (FK обоих концов),
      `softDeleteSubject`, `cascadeDeleteSubject` через reverse-индексы, **`merge`** (алиас
      провизорный→канонический) + `canonicalOf`, `provisionalSubject`.
- [x] `Cxm/Users.agda` — `User`/`RoleAssignment` (+tenant); `createUser`, `findUserByLogin`,
      `assignRole`/`revokeRole`, `ensureAdmin`, `scopedRolesOf` — в `Cxm/Commands.agda`.
      Гейт `canAssign` — на уровне Api (Фаза 8).
- [x] Напоминания (в `Cxm/Commands.agda`): `dueReminders`/`markReminded` на дедлайнах `Promise`
      (idempotent через `pmRemindedAt`).
- **DoD:** typecheck ✅. Чистые/по-построению инварианты доказаны `refl`: slot-math (`slotFree`/
      `freeSlots`), `charge` — **proof-gated by construction** (не тест, а типовой инвариант),
      id-аллокация+emit (`createSubject`/`appendEvent`), 25 record round-trip, все op-codec.
      Инварианты, требующие чтений стора (FK addEdge, cascade без dangling, merge-алиас, charge
      abort, bookSession) — в runtime-харнессе Фаз 8/11 (NatMap.lookup не редуцируется под `refl`).

---

## Фаза 7 — Производные проекции [ПР] + инференс

Читать: Описание §4.6–4.8, §4.11, §4.13, §4.16, §8.3.

- [x] `Cxm/Fact.agda` (`assertFact`), `Cxm/Trait.agda` (подвиды: `Metaprogram`,
      `Convincer{channel,mode,n}`; reality-strategy/decision-micro через generic detail;
      `inferredTrait`/`statedTrait`/`convincerTrait`/`metaprogramTrait`), `Cxm/Hypothesis.agda`
      (`hypothesize`). Все — в конверте `Knowledge`. **Добавлено поле `kDetail`** (opaque JSON):
      конверт несёт «что именно» утверждается (претензия/параметры подвида) — как payload у
      событий/ресурсов (§8.1). Ripple: Wire/Base-кодек/тесты обновлены.
- [x] `Cxm/RelationshipState.agda` — STATE с `decay` (доверие=confidence, `Trajectory`
      Up/Flat/Down + стадия в detail); экономика отношений — как `Fact`/`Hypothesis` (§4.11).
- [x] `Cxm/Projection.agda` — **чистые** проекции из [СОБ]+[ВХ]: `subjectProfile`, `activeLines`,
      `decisionUnit` (рёбра decision_consult), `eventTypeSequence` (макро-модель — последов.
      анализ). Чистые функции ⇒ **rebuild-from-scratch by construction**. Merge-алиас: передавать
      канонический id (`canonicalOf`).
- [x] `Cxm/Inference.agda` — `inferHypotheses` (правила по потоку событий), ревизия
      `strengthen`/`weaken`/`confirm`/`refute`/`supersede` (conf<1000 кламп; REFUTED сохраняет),
      `decayedConfidence`/`applyDecay` от `now`, `conflictSignal=400` (STATED↔OBSERVED сигнал,
      не затирание). Store-level `rebuildHypotheses` (Txn: очистить [ПР] + переинферить из лога).
- **DoD:** typecheck ✅. `refl`-тесты: decay от разных `now`; ревизия (confidence↑/↓ с клампом,
  REFUTED, CONFIRMED); детерминизм `inferHypotheses` (⇒ rebuild воспроизводим); проекции
  (`activeLines`/`decisionUnit`/`eventTypeSequence`/`subjectProfile`). Store-level rebuild
  идемпотентность — runtime-харнесс Фаз 8/11 (читает стор, не редуцируется под `refl`).

---

## Фаза 8 — Query/Decision API + headless HTTP

Читать: Описание §4.17, §3. Референс: `Crm/Api.agda` (envelope, routeExt, WAL config).

- [x] `Cxm/Query.agda` — Query API (чистое): `knownAbout` + `metaKPI` (`MetaKPI`: покрытие=total,
      observed/inferred split, freshness=decayed-conf≥threshold). Передавать канонический id.
- [x] `Cxm/Decision.agda` — Decision API (чистое): триггеры `expectationUnmet`/`overduePromise`/
      `sentimentDriftDown`; `priority = conf×leverage×risk`; `decide` (recovery>proactive>intervene>
      explore>exploit); `arbitrate` (внешний выигрывает, Ч2 §8.4). **Сборщик `nextBestAction`**
      (list-level: собирает триггеры субъекта) — делает Decision достижимым (аудит #A).
- [x] `Cxm/Api.agda` (`--guardedness`) — HTTP entry: envelope `{data}`/`{error}`, `errResp`,
      `cxmWalConfig` (re-export), `commit`/`commitUnit` (через `Wal.commitTxn`), `dispatchEvents`
      (`Commands.dispatchBus`), эндпойнты GET `/subjects` + POST `/subjects|/query|/decision|
      /accounts|/charge`, **`routeExt`-хук** + `route`, token-gate + `authz`-хук (где app гейтит
      `canAssign`/scope). (Роут-эндпойнты ролей — отложено, аудит #C.)
- [x] **Посев при старте (аудит Фазы 5 #C, §9.8):** `seedTenants` (в `Commands`), `seedIfEmpty`/
      `openAndSeed` (в `Api`): на пустом логе коммитит tenants. `emptyBase` не хардкодит tenant (пр.12).
- **DoD:** typecheck ✅. `refl`-тесты Query/Decision (KPI-подсчёты, decay-свежесть, все триггеры,
      порядок `decide`, арбитраж). Интеграционный GET/POST через walTxn — runtime-харнесс (IO;
      `Api` typecheck-only здесь, как `Crm.Api`).

---

## Фаза 9 — Закладки интеграции со своим сайтом (СТРОГО ОБЯЗАТЕЛЬНО)

Читать: Описание §7.7. (Реализуем именно ЗАКЛАДКИ, не UI/адаптеры.)

- [x] **API-first граница:** `routeSite` — версионные `/v1/…`, CORS (`mkResponseHRaw`+`corsHeaders`),
      OPTIONS-preflight (без токена), отделён от операторского `routeExt` (не «операторка наружу»).
- [x] **Канонический event-ingest:** `POST /v1/events` → `Commands.ingestSiteEvent` → нормализация
      в `ExperienceEvent` → append. Единственный вход фактов.
- [x] **Мост идентичности:** `Site.findIdentityIn` (cookie/user_id → subject); `ingestSiteEvent`
      (аноним → провизорный subject + Identity, §4.4); `POST /v1/login` → `mergeSession` (merge/
      промоушен). Пре-логин видимость доказана `refl` (`Site.eventsForCanonical`).
- [x] **Скоупленные интеграционные токены:** `Site.IntegrationToken{origin,scope}` +
      `tokenAuthorizes` (path-prefix scope); гейт `v1Authorized` (X-Integration-Token, verify —
      хук app через `agdelte-auth`). Аудит #A: скоуп против пути запроса.
- [x] Исходящие вебхуки: `Api.webhookSignature = hmacSHA256 secret (Site.webhookPayload topic body)`
      (паттерн payments). Доставка (POST+ретраи) — edge-адаптер (не ядро).
- **DoD:** typecheck ✅. `refl`-тесты `Site` (findIdentityIn, resolveVia, **eventsForCanonical** —
      единый опыт после merge, tokenAuthorizes, webhookPayload). End-to-end HTTP (аноним→провизорный→
      логин→merge→единый запрос) и HMAC-вебхук — runtime-харнесс (IO/postulate hmac).
      **Аудит-фиксы:** #A скоуп по пути; #B `mergeSession` снимает `sProvisional` при промоушене;
      #C пустой `externalId` → свежий субъект без привязки (не схлопывать анонимов); #D webhook без
      timestamp/nonce — помечено.

---

## Фаза 10 — Миграции и версионность (мин. заклад, §9.4)

Читать: Описание §8.5.

- [x] `Cxm/Version.agda`: `Version=ℕ`, `currentVersion=1`, `schemaVersion : String → Version`
      (регистр «версия на сущность» по имени таблицы; сейчас все v1 — аудит #C).
- [x] Хук `event-upcasting`: `Upcast = Version → RawPayload → RawPayload` (`idUpcast`/`demoUpcast`);
      **`decodeEventUpcast up from s = tolerant-decode (up from s)`** — применяется ПЕРЕД декодом
      (аудит #A). `upcastEventPayload` — удобство для эволюции внутри payload. Цепочки версий нет
      (аудит #B — каждый upcast ведёт from→current напрямую).
- [x] Tier-1 `decodeRowTolerant` переиспользован: `decExperienceEventTolerant` (аддитивные
      nullable-хвосты; byte-identical strict на полной строке).
- **DoD:** typecheck ✅. `refl`-тесты: `demoUpcast 0` апкастит payload и читается; `decodeEventUpcast`
      (порядок raw→upcast→decode); tolerant=strict на полной строке; регистр версий. ALTER-diff и
      версия в WAL-заголовке — отложены (§9.4; territory agdelte-store).

---

## Фаза 11 — Поглощение CRM + перенос pack-psych (ПРИЁМОЧНЫЙ GATE)

Читать: Описание §5, §6, §8.6. Референс: весь `agdelte-crm`, `agdelte-pack-psych`.

- [x] `Cxm/Migrate/FromCrm.agda` — **transform-on-replay** (чистый `fromCrm : List CrmOp → List
      CxmOp`): `Party→Subject`, `Engagement→Episode` (субъект = участник роли `"client"`, аудит #A),
      `Participation→SubjectEdge`, `Activity→ExperienceEvent(LifecycleChange, статус в payload)`,
      `Account/Outbox/User/RoleAssignment` как есть (+tenant), `Payment` (грант не восстановлен —
      #C), `Event→Bus.Event`. Ids переиспользуются (CRM nextId глобально уникален). `agdelte-crm`
      добавлен во временный `depend`; модуль вне `Cxm.All` (ядро crm-независимо). `refl`-тесты
      (`MigrateTest`, вне `Test.All`). Ограничения #C/#D/#E задокументированы в модуле.
      **Отложено:** IO-обёртка (чтение старого WAL Crm-декодерами → запись CXM WAL).
- [x] **Booking-функциональность перенесена в ЯДРО CXM нативно** (решение пользователя: делать
      в CXM правильно, а не портом pack-psych). Новый core-примитив `Cxm/Appointment.agda`
      (`{subject,resource,episode?,entitlement?,startsAt,durationMin,status}`, [ВХ]) — сюда
      переформулируется CRM `Activity` (§9.1). `Cxm/Schedule.agda` обогащён нейтральной календарной
      доступностью (`Settings`/`weekday`/`gridSlotsFor`/`availabilityFrom`/`validateSlot`; длина
      слота — параметр). Команды: `bookAppointment` (слот-конфликт), `bookIntoEpisode` (гард
      кредитов), `cancel/complete/noShow`, `resourceBusy`, `sessionsUsedForEpisode`. Стор вырос
      (Wire/Base/Codec/Interface). `refl`-тесты (codec, календарь). Тонкий psych-конфиг
      (каталог/часы/роуты через `routeExt`) — отдельный инкремент (край).
- [x] **Паритет booking** покрыт нативно: слоты/доступность/конфликт (`Schedule`), запись+статусы
      (`Appointment`), каталог (`Offering`), оплата→грант (`Payment`/`Entitlement`), кредиты
      пакета (`sessionsUsedForEpisode`), напоминания (`Reminders` на `Promise`). Живой end-to-end
      прогон — runtime-харнесс.
- [ ] **Удаление `agdelte-crm`** — НЕ сделано (ждёт решения). Blast radius ШИРЕ, чем «один сайт»:
      ломает сборку `agdelte/server` (7 файлов Crm*/Psych*), всю `agdelte-pack-psych`, и
      `agdelte-cxm/FromCrm`. Требует скоординированного кросс-репо сноса или миграции этих
      потребителей — по явному подтверждению.
- **DoD:** миграция данных (FromCrm) ✅; booking-функциональность в ядре CXM ✅ зелёная; удаление
  `agdelte-crm` — отложено до согласования объёма (кросс-репо).

---

## Фаза 12 — Швы облака и конфига (проверить, не реализовывать)

Читать: Описание §7.6, §9.9, §9.10, принцип 12.

- [x] Проверено: ядро = `run(core, config)` — нет module-level глобалов/postulate в `Cxm/*`
      (grep-проверка); путь WAL, активные packs, tenant-политика, seed, **API-токен** (аудит #A)
      приходят из `InstanceConfig`. IO-энтри: `Api.runInstance` (стор) + `Api.runRouter` (роутер).
- [x] Гейтинг активных packs конфигом: `Instance.packActive` (подмножество `cfgActivePacks`, §9.10)
      + `Api.gatePack` (routeExt-ext отдаётся только для активного pack; иначе `nothing`→ядро).
      Единый `Base`/`CxmOp` (принцип 7): карты неактивного pack просто пусты, не ветка кода.
- [x] Задокументировано (не реализовано) в `Cxm/Instance.agda`: control plane, DB-на-инстанс
      изоляция (§9.9, дефолт), кастомные домены, кросс-инстансная identity (OFF) — слой над ядром.
- **DoD:** `refl`-тест `InstanceTest` — один и тот же код, два конфига (`packA` активен vs пусто)
      → `packActive` различается без изменения кода ✅. Аудит-фиксы #A (`cfgApiToken`/`runRouter`);
      #B (`cfgTenantPolicy` — форвард-плейсхолдер) и #C (`gatePack` per-pack) помечены.

---

## Сквозные задачи (вести параллельно)

- [ ] Тесты на каждую фазу (round-trip кодеков, инварианты, rebuild-проекций,
      merge-алиас) — держать зелёными как DoD.
- [ ] `Cxm/All.agda` пополнять импортом каждого нового модуля (быстрый typecheck всего).
- [x] Прогонять `check-neutrality.sh` перед завершением фаз 6–8 (ядро не называет вертикали).
- [ ] Обновлять `cxm-description.md` при расхождении реализации с дизайном (описание —
      источник истины; правки — туда же).

---

## Порядок зависимостей (шпаргалка)

```
0 каркас
1 Num/Config/Tenant/Knowledge
2 Subject/Edge/Identity
3 Event(ExperienceEvent)/Bus
4 Wire (+дочерние таблицы)         ← нужны 1–3 и записи Фазы 6
5 Store.Interface/Base/Wal/Txn     ← нужен 4
6 домен-истина [ВХ] + команды      ← нужны 5; тут же довыпустить схемы для своих записей (в 4)
7 проекции [ПР] + инференс         ← нужны 6
8 Query/Decision/Api               ← нужны 7
9 site-закладки                    ← нужны 8 (+merge из 6)
10 миграции/версии                 ← параллельно с 4–5, финализ. тут
11 поглощение CRM + pack-psych      ← нужны 8–10 (GATE)
12 швы облака/конфига               ← проверка поверх всего
```

> **Примечание по Фазам 4/6:** схемы (Фаза 4) и записи домена (Фаза 6) циклически связаны —
> практично: сначала записи (Фаза 6 объявляет типы), затем их схемы дописываются в
> `Cxm/Wire.agda`. Держать Wire растущим вместе с Фазой 6.
