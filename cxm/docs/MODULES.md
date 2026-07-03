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

## 1. Слои и направление зависимостей (только ВНИЗ)

```
                    ┌────────────────────────────────────────────┐
  ВНЕШНЕЕ           │  packs (PsychCxm.*)   entry (CxmServer)    │  route→команда; env→конфиг
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L6  IO-адаптеры   │  Api (HTTP)          Worker (петля/доставка)│  --guardedness; JSON/транспорт
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L5  чтения [ПР]   │  Query Projection Decision Social (Inference*)│  чистые ф-ции над снапшотом
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L4  команды       │  Commands            (Inference.rebuild*)  │  Txn через шов; НЕ IndexedMap
                    └───────────────┬────────────────────────────┘
                    ┌───────────────▼────────────────────────────┐
  L3  движок        │  Txn   Store.Interface(шов)  Store.Wal(IO) │  единственная дверь к состоянию
                    │        Store.Base  Store.Codec              │
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

*`Inference` — явное исключение: чистая часть (decay/ревизия/правила) — L5, но
`rebuildHypotheses` — Txn-проектор (L4), поэтому модуль импортирует Txn+Interface. Разрешено
и закреплено в страже слоёв; вторая такая двойственность требует обсуждения, а не копирования.

## 2. Правила границ (и чем каждое enforced)

| # | Правило | Enforced |
|---|---|---|
| Г1 | `IndexedMap` знают ТОЛЬКО `Store.Base` и `Store.Interface` (принцип 11: репозиторный шов) | check-layering G1 |
| Г2 | IO/FFI (`Agdelte.FFI.*`, `Agdelte.Storage.WAL`) — только `Api`, `Worker`, `Store.Wal` | check-layering G2 |
| Г3 | `--guardedness` — только у Г2-модулей и зонтика `AllIO` (инфективность!) | check-layering G3 |
| Г4 | L1-записи и L5-чтения НЕ импортят `Cxm.Store.*`/`Cxm.Commands`/FFI | check-layering G4 |
| Г5 | `Wire` не импортит Store/Commands/FFI (кодек — чистый) | check-layering G5 |
| Г6 | Ядро не называет вертикали (psych/vet/…) — в т.ч. комментарии и тесты | check-neutrality |
| Г7 | Нет module-level глобалов; инстанс = f(InstanceConfig) (принцип 12) | ревью + отсутствие postulate/IORef в ядре |
| Г8 | Схемы эволюционируют ТОЛЬКО Tier-1: новые колонки в КОНЕЦ; опциональные — `CMaybe`; `dec*` — tolerant | refl-тесты «старая строка читается» (WireTest) |
| Г9 | Каждое изменение состояния = команда `Txn`; HTTP/Worker — лишь адаптеры над командами | структура модулей + ревью |

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

### L3 — движок состояния

| Модуль | Назначение | Инварианты |
|---|---|---|
| `Store.Base` | `Base` (25 IndexedMap) + `CxmOp` + `apply` + `emptyBase` | nextId≥1; индексы ВЫВОДЯТСЯ из схем (`imIndexes`) |
| `Store.Codec` | тег-байт ↔ CxmOp | exhaustive-тег на каждый Set/Del |
| `Store.Interface` | ШОВ: `Table V` + tget/tbyIndex/tscan/putT/delT/freshId | единственное место, знающее и IndexedMap, и CxmOp-конструкторы; events: `tdel = nothing` |
| `Store.Wal` (IO) | openStore/readBase/commitTxn | durable-before-visible; сериализация через WalHandle (воркер+listener без доп. локов) |
| `Txn` | инстанс генерик-монады на (Base,CxmOp,Err,apply) | abort = атомарный откат всей команды |

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
| `Query` | knownAbout, metaKPI, `reliabilityOf` | канонический subject-id (после merge) — забота вызывающего |
| `Projection` | activeLines, decisionUnit, eventTypeSequence, subjectProfile, contributionOf, coSupportShare, statusDropPeaks | функции от списков; никакого скрытого состояния |
| `Decision` | триггеры/приоритет/decide/arbitrate | внешний контур выигрывает (§8.4) |
| `Inference`* | decay/ревизия/inferHypotheses (чисто) + `rebuildHypotheses` (Txn) | REFUTED — не delete |
| `Social` | followsᵇ/entitledUpᵇ/canAccess/canList (листинг≠чтение, S7) + feedViews/threadViews (locked-тизеры; лента = только контент, не комменты) + showcaseViews (витрина: ранги+validTo-окно) + threadOf/feedOf (сырые) | грант НАСЛЕДУЕТСЯ вниз по дереву (продажа раздела одним грантом); неизвестная политика ⇒ deny; лента/тред — rebuild-from-scratch. Закладки: WS-push, "circle:<id>", переносимый Entitlement, fulfilment-as-data (П3). rUpdatedAt/updateResource — реализовано (П2) |

### L6 — IO-адаптеры

| Модуль | Назначение | Контракты |
|---|---|---|
| `Api` | HTTP: parse JSON → команда/чтение → `{data}/{error}` | ни байта HTML; два контура: операторский (`routeExt`, JWT/authz-хук) и публичный `/v1` (`routeSite`, integration-токен, CORS); listings живых сущностей фильтруют soft-deleted |
| `Worker` | петля: dueOutbox→deliver→markSent/markAttempt; runMaintenance | транспорт — параметр `deliver` (ядро наивно к сети) |

### Зонтики/тесты
`All` (чистый), `AllIO` (+guardedness), `Test/All` + 16 тест-модулей (refl = структурные
равенства и кодеки; store-read проверяется live-smoke, НЕ refl).

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
