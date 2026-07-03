# CXM — апгрейд ядра под обновлённую концепцию + завершение серверной части headless

> **Статус:** план (описание проаудировано против кода 2026-07-02, поправки внесены).
> **Что это:** (1) привести ядро `agdelte-cxm` в соответствие с апгрейдом концепции
> `~/cxm-core/docs/CXM-концепция-и-ядро.md`: блоки **C** (мелкие доукладки), **A** (экономика обещаний —
> фьючерсы), **B** (peer-контур / слой IX); (2) блок **D** — ЗАВЕРШИТЬ серверную часть
> headless-дизайна (Ч.2 §6): оркестрация действий обратно в каналы = воркер доставки Outbox
> (вебхуки/почта), периодика (напоминания, шина), недостающие поверхности.
> **Источники истины:** `~/cxm-core/docs/CXM-концепция-и-ядро.md`; код `~/.agda/agdelte-cxm/`,
> `~/.agda/agdelte/` (фреймворк+server), `~/.agda/agdelte-pack-psych-cxm/`.
> **Связь с облачным планом:** блок D ПОГЛОЩАЕТ Фазу 2 `~/cxm-core/docs/cxm-cloud-plan.md`
> (доставка вебхуков) — при выполнении D отметить её там. Фазы 3–4 облака не трогаются.
> **Исполнитель:** план self-contained — исполним с чистого контекста. Конвенции ниже.

---

## Конвенции исполнения (обязательны)

- Typecheck после КАЖДОГО изменённого модуля: `cd ~/.agda/agdelte-cxm && agda Cxm/<M>.agda`.
- После каждого блока: `agda Cxm/All.agda && agda Cxm/AllIO.agda && agda Cxm/Test/All.agda`
  и `bash scripts/check-neutrality.sh` (ядро НЕ называет вертикали: psych/vet/…).
- refl-тесты: структурные равенства (`runTxn` ops, кодек enc∘dec, чистые функции) редуцируют;
  read-back через `NatMap.lookup` — НЕ редуцирует (не писать такие refl-тесты).
- `CxmServer` пересборка: `cd ~/.agda/agdelte && npm run gen:cxm-server` затем
  `nix-shell -p zlib zlib.dev --run "cabal build cxm-server"` (zlib — грабля NixOS).
  Кэш: если cabal говорит «Up to date» после правок — `rm -rf
  dist-newstyle/build/x86_64-linux/ghc-9.10.3/agdelte-0.1.0/x/cxm-server` и пересобрать;
  если gen не перегенерил `.hs` — удалить целевой `_build/MAlonzo/Code/Cxm/<M>.hs`.
- Live-smoke через unix-сокет: `BIN=$(nix-shell -p zlib zlib.dev --run "cabal list-bin
  cxm-server")`; `CXM_SOCKET=/tmp/w/s.sock PSYCH_ADMIN_LOGIN=admin PSYCH_ADMIN_PASSWORD=secret
  "$BIN"`; запросы `curl --unix-socket /tmp/w/s.sock http://x/<path>`.
- Отмечать `- [x]` в ЭТОМ файле по мере готовности. После блока — аудит блока.

---

## Сверка «апгрейд концепции ↔ код» (факты, проверено 2026-07-02)

**Уже покрыто (НЕ трогаем):** двухосевой `Subject` + `sServes`; `Expectation↔Promise`
(met/unmet/unknown + источник); эпистемический конверт (`kStatus/kDecay/kConfidence/kDetail`);
Trait/Convincer; `eeIsPeak/eeIsEnd`; `InternalHandoff`; `decision_consult` + `seOrdinal` +
**`seRole : Maybe String` (роль в ребре УЖЕ ЕСТЬ — Cxm/Edge.agda)**; Protocol/Episode/
Transition/Deviation + `LifecycleChange`; `POST /query` (knownAbout+metaKPI) и `POST /decision`;
ingest `/v1/events` + identity-bridge + integration-токены (cloud-Фаза 1, готова);
`Version.decExperienceEventTolerant` (upcast+tolerant для событий).

**Дельта (предмет плана):**
| # | Концепт | Код сейчас | Блок |
|---|---|---|---|
| 1 | Promise: направление, holder, передаваемость, collateral (Ч.2 §3) | `Promise` = id/subject/tenant/topic/deadline/status/remindedAt/createdAt | A |
| 2 | События PROMISE_LISTED/TRANSFERRED/SETTLED/DEFAULTED | `EventType` = 7 конструкторов (View..LifecycleChange) | A |
| 3 | Двусторонний скоринг надёжности | нет first-class | A |
| 4 | `counterpart_id` на событии (peer) | нет поля | B |
| 5 | Actor `Peer`; Channel `Community` | Actor=Client/Staff/System/InternalSubject; Channel=Web..Internal+Integration | B |
| 6 | Репутация/статус, co-support, self-facing (слой IX) | нет | B |
| 7 | `Knowledge.episode_id?` (конверт §2 Ч.2) | конверт без эпизода | C |
| 8 | Рабочие стратегии (VIII.a) | Trait есть; спец-формат — конвенция | C |
| 9 | Роли DecisionUnit | **`seRole` уже есть** — только конвенция словаря | C |
| 10 | Оркестрация → каналы (Ч.2 §6 ORCH): доставка Outbox, периодика | `drainOutbox` помечает Sent БЕЗ доставки (ручной POST); таймеров в FFI НЕТ | D |
| 11 | Исходящие вебхуки с подписью | `webhookSignature` есть; доставки нет; anti-replay нет (аудит #D) | D |
| 12 | Операторское чтение лога опыта | `GET /events` = ШИНА (bus); GET по ExperienceEvent-логу НЕТ | D |

---

## Зафиксированные решения (не переигрывать)

1. **Бронь остаётся `Appointment`** (§9.1 cxm-plan; работает на сайте). Фьючерс-механика — на
   `Promise`. Связка: `apPromise : Maybe ℕ` (0-sentinel), схема+кодек в блоке A, команды брони
   его НЕ заполняют (заполнение — будущий edge-инкремент). No-show-скоринг клиента выводим из
   статусов Appointment; promise-скоринг — из Promise; оба входят в `reliabilityOf` (A4).
2. **Reputation/вклад = [ПР] проекция** (rebuild-from-scratch из peer-событий), НЕ сущность
   стора. Материализация — только если появятся nederivable-статусы.
3. **Эволюция схем.** ФАКТ КОДА: entity-кодеки (`decPromise` и т.д.) используют СТРОГИЙ
   `decodeRow`; `decodeRowTolerant` (агдельте-store) авто-дефолтит ТОЛЬКО `CMaybe`-колонки и в
   кодеки НЕ включён. Решение: (а) новые опциональные поля — `CMaybe` строго В КОНЕЦ схемы;
   (б) у ЗАТРАГИВАЕМЫХ сущностей (Knowledge/Promise/ExperienceEvent/Appointment/Outbox)
   переключить `dec*` на `decodeRowTolerant` (для полной строки byte-for-byte ≡ строгому);
   (в) не-Maybe добавки (direction/transferable/collateral/attempts) ДОПУСТИМЫ СЕЙЧАС, т.к.
   прод-WAL нет (сайт «с нуля») — но это ЛОМАЕТ чтение старых dev/test WAL: перед live-smoke
   стирать старые `*.wal`. `currentVersion` НЕ бампаем (Tier-1).
4. **Новых сущностей стора НЕТ** (Promise/Event/Edge/Knowledge/Outbox переиспользуются;
   Reputation — проекция) ⇒ НЕТ новых CxmOp-тегов; ripple ограничен схемами существующих.
5. **`PromDirection = Ours | Theirs`** (симметрия §0.2). Направление — обычная CEnumS-колонка.
6. **Роли DecisionUnit — данные** («differences are data»): словарь ролей
   (champion/blocker/economic_buyer/user/advisor) живёт в `seRole` как строки; ядро словарь
   НЕ фиксирует (enum запрещён — это конфиг вертикали/пака).
7. **AI-извлечение (Ч.4), биржа/матчинг/прайсинг (§3 «сама биржа — не ядро»), геймификация-
   механики (§3.7) — вне ядра.** Ядро даёт данные и события под них.
8. **Ядро наивно к сети (headless).** Воркер доставки в ядре (`Cxm/Worker.agda`, IO+guardedness)
   параметризован функцией `deliver : OutboxEntry → IO Bool` — транспорт (HTTP/почта) живёт в
   entry (`CxmServer`) как адаптеры. Generic исходящий HTTP — НОВЫЙ FFI-модуль фреймворка
   `Agdelte.FFI.HttpClient` (в `agdelte/src`, БЕЗ доменных слов — страж нейтральности guard 1).
9. **Таймер/фон:** в FFI сервера нет threadDelay/fork — добавить `forkLoopEvery : ℕ → IO ⊤ →
   IO ⊤` (forkIO + forever + threadDelay) в `Agdelte.FFI.Server`.
10. **Ретраи Outbox:** `obAttempts : ℕ` + `obLastAttempt : Maybe ℕ` (в конец схемы) +
    `OutStatus += OutFailed`; backoff — чистая функция `attempts → задержка(сек)`
    (экспонента с капом), потолок попыток → OutFailed. Anti-replay вебхука: заголовки
    `X-Cxm-Timestamp` + `X-Cxm-Signature = hmacSHA256 secret (ts ∥ topic ∥ body)` (закрывает
    аудит-#D; nonce не нужен — ts+podpis+идемпотентный приёмник достаточно для первой версии).
11. **Порядок: C → A → B → D**; D можно вести параллельно A/B (не пересекается по файлам,
    кроме Outbox-схемы — D2 делать ПОСЛЕ C1, чтобы один раз освоить паттерн Tier-1).

---

## Блок C — мелкие доукладки

### C1. `kEpisode : Maybe ℕ` в Knowledge-конверт
Файлы: `Cxm/Knowledge.agda`, `Cxm/Wire.agda`, call-sites, `Cxm/Test/{KnowledgeTest,WireTest}.agda`.

- [x] `Cxm/Knowledge.agda`: в `record Knowledge` добавить ПОСЛЕДНИМ полем
      `kEpisode : Maybe ℕ` (комментарий: конверт §2 Ч.2 — факт может жить на уровне эпизода:
      JTBD, пик/концовка линии; nothing = субъектный уровень). Конструктор `mkKnowledge`
      получает 12-й аргумент.
- [x] Смарт-конструкторы (сигнатуры СЕЙЧАС — цитата):
      ```
      mkFact : (kId subject : ℕ) (tenant : TenantId) (src : FactSource) (detail : String)
               (validFrom : ℕ) (validTo : Maybe ℕ) (decay : Permille) → Knowledge
      mkInferred : (kId subject : ℕ) (tenant : TenantId) (ty : InferredType)
                   (conf : Permille) {pf : True (conf <? permilleMax)} (detail : String)
                   (decay validFrom : ℕ) (validTo : Maybe ℕ) → Knowledge
      ```
      Добавить ОБОИМ параметр `(episode : Maybe ℕ)` (последним перед `→ Knowledge`), пробросить
      в `mkKnowledge`. Найти call-sites: `grep -rn "mkFact\|mkInferred" Cxm/` (Inference,
      тесты) — дописать `nothing`/конкретное значение.
- [x] `Cxm/Wire.agda` (строка ~418, `knowledgeSchema` — колонки СЕЙЧАС:
      id/subject/tenant/type/source/confidence/valid_from/valid_to/decay/status/detail):
      добавить В КОНЕЦ `∷ mkCol "episode" (CMaybe (CFK "episode"))`; `knowledgeToRow` — добавить
      `kEpisode k` последним; `knowledgeFromRow` — добить паттерн и аргумент. NB: `CMaybe (CFK _)`
      — проверить, что `decAtom`/`defaultOf` его принимают (если `CMaybe` параметризован только
      атомами без CFK — использовать `CMaybe CNat`, это тот же ℕ).
- [x] `decKnowledge`: переключить на `decodeRowTolerant` (решение 3б):
      `decKnowledge s = decodeRowTolerant knowledgeSchema s >>=ᵐ knowledgeFromRow`.
- [x] Тесты: в `Cxm/Test/WireTest.agda` — enc∘dec с `just`-эпизодом и с `nothing`; ПЛЮС
      refl-тест Tier-1: строка, закодированная БЕЗ последней колонки (буквальный литерал старого
      формата), декодится tolerant-кодеком в `kEpisode = nothing`.
- **DoD C1:** typecheck Knowledge/Wire/Inference/тесты; `Test/All` зелёный.

### C2. Рабочие стратегии (VIII.a) — конвенция, без кода
- [x] В шапку-комментарий `Cxm/Knowledge.agda` добавить абзац: рабочие стратегии — обычный
      TRAIT-конверт с `kDetail = {"kind":"work_strategy","sync":…,"detail_first":…,
      "handoff_complete_when":…}` (opaque JSON, ядро не индексирует, §8.1). Применимо и к
      INTERNAL-субъектам (VIII.a: профиль ключевого коллеги).
- **DoD C2:** комментарий; нейтральность чиста.

### C3. Роли DecisionUnit — конвенция (код уже есть)
- [x] АУДИТ-ФАКТ: `SubjectEdge.seRole : Maybe String` уже существует. Добавить в шапку
      `Cxm/Edge.agda` конвенцию: для `decision_consult` `seRole` несёт роль из словаря
      вертикали (примеры ролей — ТОЛЬКО в комментарии концепта, НЕ в коде-ядре как enum).
- **DoD C3:** комментарий; ничего не компилировать заново кроме Edge.

---

## Блок A — экономика обещаний: фьючерсы (Ч.2 §3, §9)

### A1. Расширить `Promise`
Файлы: `Cxm/Expectation.agda`, `Cxm/Wire.agda` (~752), `Cxm/Test/WireTest.agda`.

Схема СЕЙЧАС (цитата): `id / subject(idx) / tenant / topic / deadline / status(idx CEnumS
promCodes) / reminded_at(CMaybe CNat) / created_at`.

- [x] `Cxm/Expectation.agda`: `data PromDirection : Set where Ours Theirs : PromDirection`
      (+комментарий §0.2: обещания симметричны; Theirs = обещание клиента — прийти, оплатить;
      его нарушение = такой же факт опыта). В `record Promise` добавить ПОСЛЕДНИМИ полями:
      `pmDirection : PromDirection` — чьё обещание;
      `pmHolder : Maybe ℕ` — держатель, если ≠ исходному контрагенту (передано; FK subject);
      `pmTransferable : Bool` — можно ли передавать;
      `pmCollateral : ℕ` — обеспечение в minor units (0 = нет; политика размера — Decision).
- [x] `Cxm/Wire.agda`: `pdCodes = "our" ∷ "thr" ∷ []`; `pdCode`/`pdOfOrd` (по образцу
      promCode/promOfOrd рядом). В `promiseSchema` В КОНЕЦ:
      `∷ mkCol "direction" (CEnumS pdCodes) ∷ mkCol "holder" (CMaybe CNat)
       ∷ mkCol "transferable" CBool ∷ mkCol "collateral" CNat`.
      `promiseToRow`/`promiseFromRow` дописать (fromRow: `pdOfOrd` через `>>=ᵐ`).
      `decPromise` → `decodeRowTolerant` (решение 3б; NB direction/transferable/collateral НЕ
      авто-дефолтятся — старые dev-WAL с Promise не читаются, это принято решением 3в).
- [x] Все конструкторы `mkPromise` по коду (`grep -rn "mkPromise" Cxm/`) — дописать
      `Ours nothing false 0` (или по смыслу теста).
- [x] Тест WireTest: enc∘dec Promise с полным набором + `pdCode`/`pdOfOrd` в
      `Cxm/Test/EnumCodecTest.agda` (exhaustive: `pdOfOrd (pdCode d) ≡ just d` для обоих).

### A2. `EventType` += клиринговые события
Файлы: `Cxm/Event.agda`, `Cxm/Wire.agda` (~155), `Cxm/Test/EnumCodecTest.agda`.

Кодек СЕЙЧАС (цитата): `etCodes = "viw" ∷ "pur" ∷ "tko" ∷ "ftu" ∷ "ftr" ∷ "hnd" ∷ "lcc" ∷ []`,
`etCode View =0 … LifecycleChange =6`.

- [x] `Cxm/Event.agda`: `EventType += PromiseListed | PromiseTransferred | PromiseSettled |
      PromiseDefaulted` (комментарий: клиринговый журнал Ч.2 §3 — жизненный цикл передаваемого
      обещания в том же append-only логе).
- [x] `Cxm/Wire.agda`: `etCodes += "pls" ∷ "ptr" ∷ "pst" ∷ "pdf"`; `etCode` 7..10; `etOfOrd`
      7..10. Прогнать typecheck ВСЕГО (`Cxm/All.agda`) — компилятор укажет незакрытые матчи
      по EventType; в `Cxm.Api.eventTypeOf` (ingest-парсер) НЕ добавлять promise-строки
      (клиринговые события эмитит ядро, не сайт) — catch-all `View` уже тотален.
- [x] `EnumCodecTest`: 4 новых exhaustive-равенства.

### A3. Команды жизненного цикла обещания
Файл: `Cxm/Commands.agda` (образцы рядом: `createPromise`, `markPromiseFulfilled/Broken`,
`transitionEpisode` — паттерн «изменение + appendEvent в одной Txn»).

- [x] `createPromiseDirected : (subject : ℕ)(topic : String)(deadline : ℕ)(dir : PromDirection)
      (transferable : Bool)(collateral tenant now : ℕ) → Txn ℕ` — как `createPromise`, но с
      новыми полями (`pmHolder = nothing`). Старый `createPromise` оставить = обёртка
      `… Ours false 0 …` (совместимость call-sites).
- [x] `listPromise : (pid now : ℕ) → Txn ℕ` — guard `pmTransferable ≡ true` (иначе
      `Invariant "not transferable"`), guard `pmStatus ≡ PromPending`; appendEvent
      `PromiseListed` (subject = pmSubject, payload `{"promise":<pid>}`); Promise не меняется
      (размещение — факт журнала). Возвращает id события.
- [x] `transferPromise : (pid newHolder now : ℕ) → Txn ⊤` — guard transferable+Pending;
      `requireT subjectsT NotFound newHolder`; `putT` с `pmHolder = just newHolder`;
      appendEvent `PromiseTransferred` (payload `{"promise":…,"holder":…}`).
- [x] `settlePromise : (pid now : ℕ) → Txn ⊤` — guard Pending; статус `PromFulfilled` +
      appendEvent `PromiseSettled`. `defaultPromise` — симметрично `PromBroken` +
      `PromiseDefaulted`.
- [x] АУДИТ-ПОПРАВКА: A3-команды начинаются с requireT (store-read) → НЕ refl-редуцируемы (NOTE CommandsTest); проверены live-smoke A6. refl-тесты (`Cxm/Test/CommandsTest.agda`): `runTxn (listPromise …)` на Base с
      transferable-Promise эмитит ровно `SetEvent …` (структурное равенство ops);
      transfer эмитит `SetPromise` с holder + `SetEvent`; настрого — non-transferable →
      `inj₁ (Invariant _)`.

### A4. Скоринг надёжности (двусторонний)
Файл: `Cxm/Query.agda` (стиль СЕЙЧАС: чистые функции над списками — `knownAbout : ℕ → List
Knowledge → List Knowledge`, `metaKPI`).

- [x] `record Reliability : Set` = `relOursKept relOursBroken relTheirsKept relTheirsBroken
      relNoShows : ℕ` (+конструктор mkReliability).
- [x] `reliabilityOf : (subject : ℕ) → List Promise → List Appointment → Reliability` —
      счётчики: Fulfilled/Broken × Ours/Theirs по `pmSubject ≡ subject`; no-show = `ApNoShow`
      по `apSubject ≡ subject`. Чистая, refl-тестируемая.
- [x] `Cxm/Test/QueryTest.agda`: refl на конкретных списках.

### A5. `apPromise : Maybe ℕ` на Appointment (решение 1)
- [x] `Cxm/Appointment.agda`: поле ПОСЛЕДНИМ, комментарий «связка с фьючерс-Promise; команды
      брони не заполняют — edge-инкремент». `Cxm/Wire.agda` `appointmentSchema` В КОНЕЦ
      `∷ mkCol "promise" (CMaybe CNat)`; toRow/fromRow; `decAppointment` → tolerant.
      Call-sites `mkAppointment` (`grep -rn`): Commands.bookAppointment + тесты — дописать
      `nothing`.

### A6. HTTP-поверхность
Файл: `Cxm/Api.agda` (образцы: `postAssign`/`postRevoke`, диспетч ~460-500).

- [x] POST `/promises` {subject,topic,deadline,direction:"ours"|"theirs",transferable,
      collateral} → `createPromiseDirected` (парс direction: `is s "theirs"`).
      POST `/promises/list|transfer|settle|default` {id[,holder]} → A3-команды.
      GET `/promises` — листинг (энкодер `promiseJson` с новыми полями; в приватный блок
      энкодеров).
      GET `/reliability?subject=` — нет query-парсера? ФАКТ: параметры сейчас читаются из
      JSON-тела; сделать POST `/reliability` {subject} → `reliabilityOf` на
      `map proj₂ (tscan promisesT b)` и `… appointmentsT …` → JSON.
- [x] Live-smoke: создать theirs-обещание, settle, default, transfer; `/reliability`
      возвращает счётчики; всё через unix-сокет по конвенции.

**DoD блока A:** typecheck всё; EnumCodec/Wire/Commands/Query-тесты зелёные; нейтральность;
`cxm-server` собран; live-smoke пройден. Отметить [x] и провести аудит блока.

---

## Блок B — peer-контур / слой IX

### B1. `eeCounterpart : Maybe ℕ` в ExperienceEvent
- [x] `Cxm/Event.agda`: поле ПОСЛЕДНИМ (`-- вторая сторона peer-события (§0.6): оба субъекта
      внешние, наша роль — среда; nothing = обычное событие`). Конструктор станет 16-арным.
- [x] `Cxm/Wire.agda` `experienceEventSchema` (~349) В КОНЕЦ `∷ mkCol "counterpart"
      (CMaybe CNat)`; toRow/fromRow (~366); `decExperienceEvent` → tolerant (сверить с
      `Cxm/Version.agda` — там уже есть tolerant-путь, НЕ задвоить, а переиспользовать).
- [x] Call-sites `mkExperienceEvent` — ПОЛНЫЙ СПИСОК (проверен grep'ом):
      `Cxm/Commands.agda:313` (transitionEpisode), `Cxm/Api.agda:613` (postV1Events),
      `Cxm/Wire.agda:366` (fromRow), тесты: CommandsTest(38,40), ProjectionTest(37-39),
      WireTest(65,72), StoreTest(53), SiteTest(48-50), VersionTest(29,38), EventTest(17,28),
      InferenceTest(60,67,74,82,89). Всем дописать `nothing` (кроме новых peer-тестов).
- [x] Tier-1 refl-тест: старая строка события → tolerant → `eeCounterpart = nothing`.

### B2. `Actor += Peer`; `Channel += Community`
- [x] `Cxm/Event.agda`: `Peer : Actor` (другой клиент — §0.6), `Community : Channel`.
- [x] `Cxm/Wire.agda`: aCodes/aCode/aOfOrd + chCodes («com») /chCode/chOfOrd — дописать
      (Channel сейчас 0..7 c Integration=7 ⇒ Community=8). EnumCodecTest — новые равенства.
- [x] `Cxm/Api.agda channelOf` (~599): добавить `if is s "community" then Community`.

### B3. Peer-ingest через `/v1`
Файл: `Cxm/Api.agda postV1Events` (~611) + `Cxm/Commands.agda ingestSiteEvent`.

- [x] (реализовано как ОТДЕЛЬНАЯ `ingestPeerEvent`, деградирует к ingestSiteEvent при пустом counterpart) `ingestSiteEvent` расширить: опц. вторая identity (`counterpart_channel/counterpart_id`) —
      резолв/провижн ТЕМ ЖЕ identity-bridge (переиспользовать существующий resolve-путь),
      результат в `eeCounterpart`. Пустой id ⇒ nothing (как guard пустого ext сейчас).
- [x] `postV1Events`: пробросить `fieldOr req "counterpart_channel" "cookie"` /
      `fieldOr req "counterpart_id" ""`; actor: `fieldOr req "actor" ""` = "peer" → `Peer`.
- [x] Live-smoke: POST /v1/events с counterpart — оба субъекта провижинятся, событие несёт обе
      стороны (проверить листингом D5).

### B4. Проекции слоя IX
Файл: `Cxm/Projection.agda` (стиль: чистые ф-ции над списками; образец `eventTypeSequence`).

- [x] `contributionOf : (subject : ℕ) → List ExperienceEvent → ℕ` — счёт peer-событий, где
      субъект — автор (actor Peer, eeSubject = subject, counterpart ≠ nothing). Публичная
      свёртка вклада (слой IX «статус и репутация»).
- [x] `coSupportShare : List ExperienceEvent → (peer total : ℕ × ℕ)` — доля TicketOpen-подобных
      закрытий с actor=Peer против всех (метрика co-support; типы событий — параметр-предикат,
      чтобы не хардкодить смысл: `(ExperienceEvent → Bool) → …`).
- [x] `statusDropPeaks : (subject : ℕ) → List ExperienceEvent → List ExperienceEvent` —
      негативные пики (eeIsPeak ∧ sentiment < нейтрали) с actor=System на канале Community
      (потеря статуса создана механикой — §слой IX).
- [x] `Cxm/Test/ProjectionTest.agda`: refl на конкретных списках (3 функции).

### B5. Peer-ребро — НЕ добавлять впрок
- [x] Зафиксировано: `follow` покрывает подписку; отдельный `peer`-EdgeKind добавлять ТОЛЬКО
      когда появится потребитель (проекция/запрос), которому не хватит follow+counterpart.

### B6. Self-facing прогресс через `/v1`
- [x] `Cxm/Api.agda routeSite`: `POST /v1/me/progress` (+CxmServer диспетч по ПРЕФИКСУ /v1/ — новые /v1-роуты не требуют правки entry) {identity_channel,identity_id} →
      резолв субъекта (identity-bridge, БЕЗ провижна — незнакомый id ⇒ 404) →
      `contributionOf` → `{"data":{"contribution":N}}`. За integration-токеном (уже гейтится).
- [x] Live-smoke: после B3-событий прогресс автора ≥ 1.

**DoD блока B:** typecheck; тесты (Wire/Enum/Projection) зелёные; Tier-1-тест события;
нейтральность; live-smoke B3+B6. Отметить [x], аудит блока.

---

## Блок D — завершение серверной части headless (оркестрация → каналы)

Закрывает Ч.2 §6 «ORCH: оркестрация действий обратно в каналы» + cloud-план Фазу 2.
АУДИТ-ФАКТЫ: таймер/fork в FFI отсутствуют; generic исходящего HTTP нет (YooKassa-клиент —
специализированный); `drainOutbox` помечает Sent без доставки; `GET /events` = шина, лога
опыта нет; `OutStatus = OutPending | OutSent`; `OutboxEntry` = id/channel/to/subject/body/
status/tenant/createdAt.

### D1. FFI фреймворка (`~/.agda/agdelte`, нейтрально — guard 1 стража)
- [x] `src/Agdelte/FFI/Server.agda`: `forkLoopEvery : ℕ → IO ⊤ → IO ⊤` —
      `forkIO (forever (action >> threadDelay (sec*1e6)))`; COMPILE GHC по образцу
      listenUnix (import Control.Concurrent). Первый прогон — СРАЗУ (до первой задержки).
- [x] НОВЫЙ `src/Agdelte/FFI/HttpClient.agda`: `HttpClientManager` (opaque),
      `newHttpClientManager : IO HttpClientManager`,
      `httpPostStatus : HttpClientManager → (url body : String) →
       List (String × String) → IO ℕ` — POST, вернуть HTTP-статус (0 = сетевая ошибка;
      никаких исключений наружу). GHC: http-client/http-client-tls (deps уже в cabal
      cxm-server). Никаких доменных слов в модуле.
- [x] Пересобрать: `npm run gen:cxm-server` увидит новые модули; typecheck agdelte-стороной:
      `agda -i src src/Agdelte/FFI/HttpClient.agda`.

### D2. Outbox-ретраи (ядро)
Файлы: `Cxm/Bus.agda`, `Cxm/Wire.agda` (outboxSchema), `Cxm/Commands.agda`.

- [x] `Cxm/Bus.agda`: `OutStatus += OutFailed`; `OutboxEntry` += ПОСЛЕДНИМИ
      `obAttempts : ℕ`, `obLastAttempt : Maybe ℕ`.
- [x] `Cxm/Wire.agda`: outCodes (osCodes)  += "fld"; outCode/outOfOrd += 2; outboxSchema В КОНЕЦ
      `∷ mkCol "attempts" CNat ∷ mkCol "last_attempt" (CMaybe CNat)`; toRow/fromRow;
      `decOutbox` → tolerant. Call-sites `mkOutbox` (Commands.enqueueNotification + тесты) —
      дописать `0 nothing`.
- [x] `Cxm/Commands.agda`:
      `backoffSec : ℕ → ℕ` — чистая: `attempts² * 60`, кап 3600 (refl-тестируемо);
      `dueOutbox : (now maxAttempts : ℕ) → Txn (List ℕ)` — id'ы Pending, у которых
      `lastAttempt + backoffSec attempts ≤ now` (nothing ⇒ сразу);
      `markAttempt : (oid now maxAttempts : ℕ) → Txn ⊤` — attempts+1, lastAttempt=just now;
      если attempts+1 ≥ maxAttempts ⇒ статус OutFailed;
      `markSent` уже есть.
- [x] Обновить `Cxm.Api.outStatusStr` (+ "failed") и всё, что матчит OutStatus (компилятор
      покажет). refl-тесты: backoffSec; runTxn markAttempt (ops).

### D3. Воркер доставки (ядро, IO)
- [x] НОВЫЙ `Cxm/Worker.agda` (`--without-K --guardedness`; добавить в `Cxm/AllIO.agda`):
      `runOutboxOnce : WalHandle Base CxmOp → (deliver : OutboxEntry → IO Bool) →
       (now maxAttempts : ℕ) → IO ℕ` — прочитать due (commitTxn dueOutbox), для каждого
      `deliver`; true → commitTxn markSent, false → commitTxn markAttempt; вернуть счёт
      доставленных. Ядро НЕ знает транспорта (решение 8).
      `runMaintenance : WalHandle → (now lead : ℕ) → IO ⊤` — commitTxn
      (remindDueAppointments now lead) >> commitTxn dispatchBus >> pure tt (периодика ядра).
- [x] refl тут не применим (IO) — smoke в D4.

### D4. Адаптеры + wiring в `CxmServer`
Файл: `~/.agda/agdelte/server/CxmServer.agda`.

- [x] Env: `CXM_WORKER_SEC` (0 = воркер выключен; иначе интервал), `CXM_WEBHOOK_SECRET`,
      `CXM_MAX_ATTEMPTS` (default 8), `CXM_REMIND_LEAD_H` (default 24).
- [x] Адаптер: `deliver : OutboxEntry → IO Bool` —
      channel "webhook" ⇒ `httpPostStatus mgr (obTo e) (obBody e) headers`, где headers =
      `X-Cxm-Topic: obSubject`, `X-Cxm-Timestamp: <now>`,
      `X-Cxm-Signature: webhookSignature secret (obSubject) (ts ∥ obBody)` (anti-replay,
      решение 10); success = 200 ≤ status < 300;
      channel "email" ⇒ ПОКА лог-заглушка `putStrLn` + true (доставка почты — отдельный
      adapter-инкремент; НЕ блокирует headless-контур);
      прочие каналы ⇒ true (совместимость со старыми интентами).
- [x] Wiring: после `seedAdmin`, если `CXM_WORKER_SEC > 0`:
      `forkLoopEvery sec (getCurrentTime >>= λ now → runOutboxOnce h deliver now maxAtt >>
       runMaintenance h now (lead*3600))`. Затем listen как сейчас.
- [x] Live-smoke (конвенция + свежий WAL): (1) enqueue вебхука оператором
      `POST /notifications {channel:"webhook", to:"http://127.0.0.1:8137/outbox/drain", …}` —
      поднять ВТОРОЙ dev-инстанс на TCP :8137 как приёмник-200; воркер доставляет → outbox
      листинг показывает sent; (2) приёмник-404 (несуществующий путь) → attempts растут,
      после maxAttempts → failed; (3) reminders/dispatch крутятся без ручных POST.

### D5. Операторское чтение лога опыта
- [x] `Cxm/Api.agda`: приватный `experienceJson : ExperienceEvent → String` (id/subject/
      counterpart/channel-как-строка/actor/type/timestamp/episode/sentiment/isPeak/isEnd —
      строковые формы enum'ов дописать рядом с apStatusStr) и
      `GET /experience-events` → листинг `eventsT` (append-only — без live-фильтра).
      Диспетч: в GET-ветку рядом с `/events`.
- [x] Smoke: после B3/D4 события видны.

**DoD блока D:** typecheck agdelte+cxm; `cxm-server` собран; live: доставка/ретрай/фейл;
периодика работает; `GET /experience-events` отдаёт лог; нейтральность обоих стражей
(agdelte guard 1 — новый FFI без доменных слов); cloud-план Фаза 2 отмечена выполненной.

---

## Порядок и зависимости

```
C1 (kEpisode, Tier-1 паттерн) → C2/C3 (конвенции)
A1→A2→A3→A4→A5→A6 (внутри блока строго по порядку)
B1→B2→B3→B4→B6 (B5 — гейт «не делать впрок»)
D1 (FFI) → D2 (outbox-схема; после C1) → D3 → D4 → D5
C — первым; A и B — по порядку; D параллелен A/B (пересечение только D2↔схемы)
```

## Риски

- **Строгий decodeRow (главный):** правки схем ломают чтение СТАРЫХ WAL; прод-данных нет, но
  каждый live-smoke — со СВЕЖИМ WAL; tolerant-переключение делает будущие CMaybe-добавки
  безопасными, не-Maybe — нет (осознанно, решение 3в).
- **Тотальность матчей:** новые конструкторы (EventType/Actor/Channel/OutStatus) разойдутся по
  Wire/Api/Projection — компилятор укажет; НЕ затыкать catch-all там, где семантика различна
  (пример: `outStatusStr`, `channelOf`).
- **`CMaybe (CFK _)`** может не поддерживаться store-схемой — fallback `CMaybe CNat` (C1/B1).
- **forkIO-воркер и WAL:** commitTxn сериализуется через WalHandle (STM в agdelte-store) —
  конкуренция listen-тредов и воркера уже покрыта той же дверью; ничего дополнительно не строить.
- **Нейтральность FFI:** `Agdelte.FFI.HttpClient` в guard-1-зоне (src/) — никаких
  party/engagement/услуг-слов.
- **Anti-replay:** ts в подписи (решение 10) — приёмник обязан проверять окно ts; это контракт
  для сайтов (задокументировать в cloud-Фазе 3 SDK).
