# agdelte-cxm — границы модулей и спецификации

> **Конвенция (обязательная): модуль проектируется ВМЕСТЕ со спецификацией.**
> Спека модуля живёт в двух местах: (1) **шапка-комментарий самого файла** — назначение,
> контракты, ссылки на §§ концепта/плана (полная форма); (2) **строка в каталоге ниже** —
> слой, граница, инварианты (сводная форма). Новый модуль без обоих — незавершён.
> Границы проверяются МЕХАНИЧЕСКИ: `scripts/check-layering.sh` (слои) +
> `scripts/check-neutrality.sh` (доменная нейтральность). Оба обязаны быть зелёными.
>
> Термины: [СОБ] append-only источник истины; [ВХ] write-model; [ПР] перестраиваемая проекция.

---

> **Фронт-слой (cxm-ui):** контракт-привязанные виджеты и типизированный HTTP-клиент живут в
> отдельной либе `~/cxm-core/cxm-ui/` (depend: stdlib+agdelte, Agda-ядро НЕ импортирует — страж
> G4 в check-layering.sh). Карта модулей и API для авторов сайтов: `cxm-ui/README.md`.

> **★ POSTGRES-ONLY (2026-07-07).** WAL + in-memory движок УДАЛЁН (`Cxm.Commands`/`Txn`/`Api`/
> `Worker`/`Store.Interface`/`Store.Wal`/`Store.Codec`/`Store.Tx2`/`Store.VerbsBase` + generic
> `IndexedMap`/`NatMap`/`WAL`/`Txn`). Стор — типизированный EDSL, компилирующийся в SQL. Команды
> пишутся Tx-верболами (`Cxm.Store.Verbs`) в `Cxm.CommandsV` и отдаются в один `runCxmTx`;
> исполнение — `Cxm.Store.Pg` (вербол→SQL). Ниже — актуальная (PG) картина; детали стор-EDSL:
> `~/cxm-core/docs/edsl-intro.md`, контракты: `~/cxm-core/docs/pg-store-plan.md`.

## 1. Слои и направление зависимостей (только ВНИЗ)

```
                    ┌────────────────────────────────────────────┐
  ВНЕШНЕЕ           │  packs (PsychCxm.*)   entry (server/CxmServerPg) │  route→команда; env→конфиг
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L6  IO/exec       │  Store.Pg (вербол→SQL; runCxmTx=BEGIN…COMMIT)│  --guardedness; единственная
                    │                                             │  дверь к драйверу/IO
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L5  чтения [ПР]   │  Projection Decision Social Inference        │  чистые ф-ции над снапшотом
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L4  команды       │  CommandsV (Tx-верболы → runCxmTx)          │  атом = один терм; локи-верболы
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L3  стор-EDSL     │  Store.Verbs (алгебра+эргослой)  Store.Tables │  вербол-алгебра + проводка
                    │  Store.Registry  Store.Base(Err+инд-позиции) │  схем; интерпретаторы:
                    │  Store.VerbsTest (чистый эталон/тест-дубль)  │  чистый ↔ Pg (L6)
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L2  провод        │  Wire (схемы/кодеки)   Version (upcast)    │  Tier-1 эволюция
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L1  записи+чистое │  Tenant Subject Edge Identity Event Bus     │  типы данных, смарт-
                    │  Knowledge Collections Offering Resource    │  конструкторы, чистая
                    │  Entitlement Account Payment Expectation    │  математика; НОЛЬ импортов
                    │  Protocol Episode Users Appointment Site    │  выше своего слоя
                    │  Num Config Schedule Fact Hypothesis Trait  │
                    │  RelationshipState Instance                 │
                    └────────────────────────────────────────────┘
```

Генерик стор-EDSL (`Agdelte.Storage.{Schema,SQL,Free,FreeIO,JsonRow,PgConn,Migration,Query,FFI,
Postgres}`) живёт в `agdelte-store` — домен-нейтрален; `Cxm.Store.*` привязывает его к 28 таблицам.
`Inference` теперь ЧИСТ (детерминированная ф-ция лога, L5) — прежний Txn-проектор `rebuildHypotheses`
удалён с WAL; verb-порт (`rebuildInferenceV`) — известный post-cutover пробел.

## 2. Правила границ (и чем каждое enforced)

| # | Правило | Enforced |
|---|---|---|
| Г1 | Драйвер/IO (`Agdelte.FFI.*`, `Storage.{Postgres,FFI,PgConn,FreeIO}`) — ТОЛЬКО `Store.Pg` | check-layering G1 |
| Г2 | `--guardedness` (инфективно!) — ТОЛЬКО `Store.Pg` | check-layering G2 |
| Г3 | L1-записи и L5-чтения (вкл. чистый `Inference`) НЕ импортят `Cxm.Store.*`/драйвер | check-layering G3 |
| Г6 | Ядро не называет вертикали (psych/vet/…) — в т.ч. комментарии и тесты | check-neutrality |
| Г7 | Нет module-level глобалов; инстанс = f(InstanceConfig) (принцип 12) | ревью + отсутствие postulate/IORef в ядре |
| Г8 | Схемы эволюционируют ТОЛЬКО Tier-1: новые колонки в КОНЕЦ; опциональные — `CMaybe`; `dec*` — tolerant | refl-тесты «старая строка читается» (WireTest) |
| Г9 | Каждое изменение состояния = Tx-верболы в один `runCxmTx` (атом); сервер — адаптер над командами | структура модулей + ревью |

## 3. Каталог модулей (сводные спеки)

### L1 — записи и чистые модели (без импортов выше слоя)

| Модуль | Назначение | Ключевые инварианты / контракты |
|---|---|---|
| `Num` | Permille (0..1000), Sentiment-offset | clamp; кодеки ℤ↔ℕ тотальны |
| `Tenant` | ось владельца; `defaultTenant = 1` | tenant-поле на каждой сущности (принцип 8) |
| `Config` | `InstanceConfig` — ЕДИНСТВЕННЫЙ вход конфигурации | никакого чтения env внутри ядра |
| `Subject` | 2 оси (Person/Org × EXTERNAL/INTERNAL), provisional, `sServes` | B2C = вырожденный B2B (схлопывание, не режим) |
| `Edge` | генерик subject↔subject (`seKind`,`seRole`,`seOrdinal`) | словарь ролей — данные пака, НЕ enum ядра |
| `Identity` | канальный id → Subject (сердце identity-resolution) | «email клиента» живёт ЗДЕСЬ, не в Subject |
| `Event` | `ExperienceEvent` [СОБ]: канал/актор/тип/аннотации/`eeCounterpart` | append-only; НЕТ DelEvent; peak/end — маркеры памяти |
| `Bus` | доменная шина + Outbox-интент (attempts/lastAttempt) | три лога НЕ смешивать (§8.2): WAL / ExperienceEvent / шина |
| `Knowledge` | эпистемический конверт (+`kEpisode`) | инварианты §4.1 — ЧЕРЕЗ смарт-конструкторы; сырой `mkKnowledge` только для кодека |
| `Fact/Hypothesis/Trait/RelationshipState` | тонкие конструкторы над конвертом | INFERRED ⇒ conf<1000 (proof-gated) |
| `Collections` | дочерние таблицы (Evidence/Transition/Deviation/ProtocolState/ProtocolTransition) | Schema атомарна ⇒ коллекции = дочерние строки (§8.1) |
| `Offering/Resource(+ResourceLink)/Entitlement/Account/Payment/Expectation/Protocol/Episode/Users/Appointment` | [ВХ] домен; ResourceLink = кураторский ГРАФ ссылок (витрина/промо: rank+validTo=проданный слот); Mention = упорядоченные адресаты коммента (0=основной, inbox по subject-индексу); Resource несёт anchor(kind,id)+streamRoot — разговоры от ЛЮБОЙ сущности, права по-потоково (§10) | Appointment = операционная бронь (реш. §9.1); Promise-экономика — на Expectation.Promise |
| `Expectation` | Expectation↔Promise (+direction/holder/transferable/collateral) | симметрия §0.2; фьючерс-лайфцикл журналируется |
| `Schedule` | чистая календарная математика | slot-длина/часы — параметры, не константы вертикали |
| `Site` | identity-bridge helpers, IntegrationToken (+IntTokenRow), webhookPayload | resolve БЕЗ провижна на чтении |
| `Instance` | `packActive` — гейтинг паков конфигом | один бинарь, подмножества паков = данные |

### L2 — провод

| Модуль | Назначение | Инварианты |
|---|---|---|
| `Wire` | Schema per запись ⇒ кодек+индексы+DDL; enum-кодеки | round-trip `dec∘enc ≡ just`; Tier-1 (Г8); индекс-позиция = порядок `idxCol` |
| `Version` | schemaVersion + upcast-хук (ДО декода) | tolerant≡strict на полной строке |
| `Fulfilment` | ЧИСТЫЙ интерпретатор плана исполнения из `Offering.oMetadata` (П3, fulfilment-as-data): `parseFulfilment : String → List Grant` | толерантный токенайзер kind:id (не JSON-парсер: ядро без чистого JSON, L4 без FFI); план — server-side ДАННЫЕ, привилегия не подделывается из запроса; тотален; промисы-в-плане — закладка |

### L3 — стор-EDSL (привязка генерик-движка к 28 таблицам)

| Модуль | Назначение | Инварианты |
|---|---|---|
| `Store.Verbs` | вербол-алгебра (Req/Ans-GADT ×28) + freer `Tx` + эргослой (get/require/byIx/byCol/scan/put/del/fresh/lockRoot/lockKey) + `rootOf`/`altRoots`/`appendOnly`/`queueTable` | атом = один `Tx`-терм; локи-верболы (unlock невыразим ⇒ 2PL структурно); `lockRoots` канон-порядок |
| `Store.Tables` | `TableCode` → tableName/schemaOf/toRowOf/fromRowOf + idxCols/idxColTys | мост-refl к Wire; pk="id"; индекс-позиции пиннятся |
| `Store.Registry` | реестр 28 таблиц (`dumps`) → `cxmSchemas`/`genesis`/`cxmHistory` + сторож `migrate history [] ≡ cxmSchemas` | заморозить `cxmHistory` в литерал на первом прод-деплое |
| `Store.Base` | НЕЙТРАЛЬНО: `Err` + позиции вторичных индексов (ℕ-константы) | ноль зависимостей от бэкенда; позиции = порядок `idxCol` |
| `Store.VerbsTest` | чистый function-state хэндлер (`handlerP`) — эталон + чекер lock-дисциплины | refl-тесты без БД; гонка ⇒ красный тест |

*(интерпретатор в SQL — `Store.Pg`, L6)*

### L4 — команды (все записи состояния)

| Группа | Команды | Контракты |
|---|---|---|
| Субъекты | create/provisional/resolveOrCreate/merge/canonicalOf/softDelete/cascadeDeleteDeep | merge = алиас, не переписывание [СОБ] |
| Деньги | openAccount/charge/credit | charge proof-gated (баланс ≥ 0 by construction) |
| Ingest | appendEvent/ingestSiteEvent/ingestPeerEvent | лог не ждёт резолва (provisional) |
| Линии | createProtocol/ensureProtocol/addProtocolState/addProtocolTransition/createEpisode/transitionEpisode | переход только по правилу; переход журналируется (Transition + LifecycleChange) |
| Бронь | book/bookIntoEpisode/cancel/complete/noShow/reopen/resourceBusy/sessionsUsed | слот-конфликт в команде; кредит-гард |
| Обещания (П6: контролируемые) | createPromiseDirected(+stake)/list/transfer(+penaltyTo)/refer/settle/default + reminders | промис = будущее событие + объявленное СЛЕДСТВИЕ-на-дефолт; ставка удержана `charge` (proof-gated ⇒ штраф ≤ ставки); settle→release, default→route(penaltyTo\|forfeit)+PromiseDefaulted, всё ОДНОЙ Txn (broken⟹следствие атомарно); transfer=смена получателя (claim следует), refer=смена исполнителя (ставка следует); мутация на месте, pmId стабилен. Внешний payout/цепочки/N-контракты — вне scope |
| Платежи | recordPayment/markPaymentSucceeded/findByExtId + **fulfillOffering** (П3) | идемпотентный грант; на успех платежа fulfillOffering читает план оффера и выдаёт гранты (SPayment) — покупка узла без оператора, всё в ОДНОЙ Txn с деньгами |
| Outbox | enqueueNotification/markSent/markAttempt/dueOutbox/backoffSec/drainOutbox | at-least-once; OutFailed — аудит-строка |
| RBAC-данные | createUser/assignRole/revokeRole/scopedRolesOf/ensureAdmin | enforcement — хук, не здесь |
| Интеграция | createIntegrationToken/revokeIntegrationToken | секрет генерится на IO-краю |
| Соцсеть/разговоры | publishResource/followSubject/linkResource/unlinkResource/commentOn(+requireAnchor, anchorParticipantᵇ) | якорь валидируется; F4: автор обязан быть в аудитории якоря (Forbidden); reply игнорирует ak/ai запроса (наследование/parent-as-anchor); Publish/Reaction-событие в той же Txn |
| Гигиена блога (П2) | updateResource/updateOwnResource | патч-семантика (nothing = keep; сброс политики — только явным значением); правка только LIVE-узла (NotFound); rUpdatedAt штампуется КАЖДОЙ правкой; own-форма: rAuthor ≡ caller (Forbidden — в т.ч. на безавторский операторский контент) |

### L5 — чтения (чистые, rebuild-from-scratch)

| Модуль | Экспортирует | Инварианты |
|---|---|---|
| `Projection` | activeLines, decisionUnit, eventTypeSequence, subjectProfile, contributionOf, coSupportShare, statusDropPeaks | функции от списков; никакого скрытого состояния |
| `Decision` | триггеры/приоритет/decide/arbitrate | внешний контур выигрывает (§8.4) |
| `Inference` | decay/ревизия (strengthen/weaken/confirm/refute/supersede)/inferHypotheses — ЧИСТО | детерминированная ф-ция лога (rebuild-from-scratch); REFUTED — не delete; store-rebuild — `CommandsV.rebuildInferenceV` (per-subject, owner-scoped) |
| `Social` | followsᵇ/entitledUpᵇ/canAccess/canList (листинг≠чтение, S7) + feedViews/threadViews (locked-тизеры; лента = только контент, не комменты) + showcaseViews (витрина: ранги+validTo-окно) + threadOf/feedOf (сырые) | грант НАСЛЕДУЕТСЯ вниз по дереву (продажа раздела одним грантом); неизвестная политика ⇒ deny; лента/тред — rebuild-from-scratch. Закладки: WS-push, "circle:<id>", переносимый Entitlement, fulfilment-as-data (П3). rUpdatedAt/updateResource — реализовано (П2) |

### L6 — IO/exec (единственная дверь к драйверу)

| Модуль | Назначение | Контракты |
|---|---|---|
| `Store.Pg` | `exec : Conn → (r:Req) → IO (Err ⊎ Ans r)` (вербол→ОДИН SQL-стейтмент) + `runCxmTx = FreeIO.runTxPg` (BEGIN→fold→COMMIT/ROLLBACK) | `--guardedness`; ixColName/ixKeyLit по типу из схемы (G2: CBool→TRUE/FALSE); SELECT без хвостовой `;` (G1); append-only отвергает del |

Сам HTTP-сервер — `~/cxm-core/server/CxmServerPg.agda` (роуты→команды `CommandsV`, RBAC, /v1, PG-воркер+nudge);
диагностика — `PgDiff` (native≡PG) и `PgBench` (чаттинес). Все три — вне `Cxm/` (build-харнесс `agdelte`).

### Зонтики/тесты
`Test/All` + тест-модули (refl = структурные равенства и кодеки; store — через чистый `handlerP`
и live `pg-diff`, НЕ refl). WAL-эра тесты (Commands/Store/Query) удалены с движком.

## 4. Стабильные внешние контракты (менять только аддитивно)

1. **HTTP-конверт**: всегда `{"data":…}` | `{"error":{code,message}}`; коды ошибок = Err-маппинг.
2. **Публичный `/v1`** (для ЛЮБОГО сайта): `POST /v1/events` (identity_channel/identity_id[,
   counterpart_*, actor, channel, type, payload]), `POST /v1/login`, `POST /v1/me/progress`,
   `POST /v1/resource/update` (правка СВОЕГО поста; "" = keep), `POST /v1/me/mentions`
   (inbox упоминаний: since-курсор по id УПОМИНАНИЯ, asc; узлы — под теми же F4/canList/locked-гейтами,
   что /v1/conversation), `POST /v1/purchase {offering}` (self-service: identity-bridge →
   pending-платёж по цене оффера; fulfilment — ТОЛЬКО на /payments/succeed, НЕ здесь);
   заголовок `X-Integration-Token`; CORS. Новые пути — только под `/v1/` (entry диспетчит префиксом).
   Операторские (за JWT/token): `GET/POST /offerings` (metadata = план исполнения),
   `POST /payments/succeed {id}` (провайдер/оператор подтверждает платёж → грант+fulfilment;
   НЕ публичный — покупатель не подтверждает свой платёж).
3. **Исходящий вебхук**: POST c `X-Cxm-Topic`, `X-Cxm-Timestamp`,
   `X-Cxm-Signature = hmacSHA256(secret, topic ∥ (ts∥body))`; приёмник обязан быть идемпотентным
   и проверять окно ts.
4. **Wire-формат**: правки только Tier-1 (Г8). Не-Maybe добавка = слом старых WAL — допустимо
   только пока нет прод-данных, всегда с явной пометкой в плане.

## 5. Чек-лист изменения (вместо памяти — процедура)

**Новый модуль**: шапка-спека (назначение/§§/инварианты/запреты) → строка в §3 → место в DAG §1
(если новый слой/исключение — обновить страж) → refl-тесты на чистое → `check-layering` +
`check-neutrality` + `Test/All` зелёные.

**Новое поле сущности**: поле В КОНЕЦ записи → колонка В КОНЕЦ схемы (`CMaybe`, если опционально)
→ toRow/fromRow → `dec*` tolerant → call-sites конструктора → refl round-trip + Tier-1-тест
старой строки → JSON-энкодер Api (если публикуется).

**Новая команда**: сигнатура через шов (никакого IndexedMap) → гарды `guardT/requireT` →
журнальное событие в той же Txn, если факт опыта → HTTP-роут (тонкая обёртка) → live-smoke.

**Новый enum-конструктор**: конструктор → `xCodes/xCode/xOfOrd` → exhaustive refl в EnumCodecTest
→ пройтись по total-матчам, которые укажет компилятор (НЕ затыкать catch-all, где семантика различна).

## 6. Корректность по построению: что уже ТИПЫ, что ещё ТЕКСТ (аудит-2, 2026-07-03)

**Уже enforced типами (не ревью, не грепом):**
| Инвариант | Механизм |
|---|---|
| Баланс ≥ 0 | proof-gated `debit` (единственный источник proof — yes-ветка `_≤?_`) |
| INFERRED ⇒ conf < 1000 | `mkInferred {pf : True (conf <? permilleMax)}` |
| FACT ⇒ source ∈ {OBSERVED,IMPORTED} ∧ conf=1000 | тип `FactSource` + smart-конструктор |
| ExperienceEvent неудаляем | `eventsT .tdel = nothing` (Del-оп невыразим через шов) |
| **Якорь без id / streamRoot без якоря непредставимы** | **`rConv : Maybe ConvCtx` — ОДИН Maybe вместо трёх параллельных (аудит-2 CBC-рефактор); старые имена полей сохранены производными аксессорами** |
| Кодек тотален на конкретных значениях | refl-тесты enc∘dec + exhaustive enum + Tier-1 старых строк |
| Слои не смешиваются | import-структура + check-layering (греп по РЕАЛЬНЫМ import) |

**Пока текст/греп/дисциплина (кандидаты на будущую типизацию):**
- Г8 «колонки только в конец» — конвенция+refl-тест; типом стало бы «Schema-эволюция как
  индексированный тип» (agdelte-store territory).
- «streamRoot корректно унаследован» — держится тем, что писать умеет только `commentOn`;
  типом — параметризованный конструктор комментов.
- Политики-строки (public/followers/entitled) — данные по решению («differences are data»);
  НЕ типизировать. Якорь-kind — закрытое множество таблиц ядра: КАНДИДАТ на enum (уберёт
  ветки «unknown ⇒ deny/error» по построению; отложено — /v1 всё равно парсит строку на краю).
- Спека модулей в Agda (замечание пользователя): реалистичный путь — НЕ «перенести MODULES.md»,
  а поштучно переводить строки таблицы в типы/refl-леммы (как ConvCtx сегодня) + держать
  каталог текстом для человека. Каждый перенос отмечать переносом строки из «текст» в «типы».
