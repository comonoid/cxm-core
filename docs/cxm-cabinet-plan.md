> **★ ОБНОВЛЕНО 2026-07-07 — стор: Postgres-only.** WAL + in-memory движок УДАЛЁН (движок и старые
> WAL-команды снесены; сервер — `cxm-server-pg` на живом PG). Любые упоминания WAL / memory-image /
> «ждёт драйвера» / «Postgres отложен» НИЖЕ — ИСТОРИЯ. Актуальная модель хранения, статус и контракты:
> **`docs/pg-store-plan.md`**.

# CXM-кабинет — операторская поверхность клиентского опыта («умный блокнот»)

> **Статус:** план (2026-07-03), ведётся по ходу. Отмечать `- [x]`. Self-contained.
> **Конвенции исполнения** — как в остальных фазах: typecheck на модуль (`cd ~/cxm-core/cxm &&
> agda Cxm/<M>.agda`); стражи `scripts/check-{layering,neutrality}.sh` зелёные; refl-тесты
> (структурные равенства/кодеки — НЕ store-read); Tier-1 схем (CMaybe в конец, tolerant); пересборка
> `cd ~/.agda/agdelte && npm run gen:cxm-server && cabal build cxm-server` (nix-shell -p zlib zlib.dev);
> live-smoke через unix-сокет; спека модуля вместе с модулем (`docs/MODULES.md`); аудит фазы с
> адверсариями. Каждое изменение состояния = команда `Txn`; HTTP — тонкая обёртка.

## Замысел (не переигрывать)

Кабинет = **операторский** (психолог ВЕДЁТ клиентов), не self-facing клиентский. Цель — выставить
всю **клиент-опытную машинерию CXM** как «умный блокнот»: хранить/обновлять инфо о клиенте и об
опыте работы, различать workflow (привлечение → работа → перепродажа серий), видеть ленту опыта,
знания/гипотезы, профиль, подсказки. Психологи — первый полигон (у них workflow небогатый).

## Зафиксированные решения

Р1. **Соц-платформа ГОТОВА в ядре — не трогаем** (перепроверено 2026-07-03): контент
    (`/v1/publish`,`/v1/resource/update`), продажа (`/offerings`,`/v1/purchase`,`fulfillOffering`,
    `/payments/succeed`), доступ (`public/followers/entitled` + наследование гранта вниз + locked-тизер
    + `/entitlements`), публичное общение (`/v1/comment·thread·conversation·me/mentions·follow·me/feed`).
Р2. **Workflow = Protocol + Episode — машинерия ЕСТЬ** (`/protocols`(+state/transition),
    `/episodes`(+transition)). «Привлечение» и «работа» = РАЗНЫЕ протоколы (стейт-машины как ДАННЫЕ);
    серия консультаций = Episode; **перепродажа = НОВЫЙ Episode** (уже открывается на покупке:
    `PsychCxm.Payments.grantTxn` → `ensureProtocol`+`createEpisode`). Новой логики НЕ надо — нужны
    протоколы-как-данные (seed/config) + by-subject чтения + фронт.
Р3. **Хранение/обновление инфо о клиенте и опыте = Knowledge-конверт** (эпист.: status/confidence/
    decay/detail/episode) + `ExperienceEvent` (лента) + `Subject`/`Identity`. **Ревизия и будущее
    автозаполнение = `Cxm.Inference`** (decay/strengthen/weaken/confirm/refute/supersede + Txn
    `rebuildHypotheses`) — логика ЕСТЬ (pure). Пробел — команда записи/правки + HTTP.
Р4. **Промисы — ВНЕ scope** (решение пользователя).
Р5. **Приватное общение психолог↔клиент = якорный разговор** (F4-гейт: разговор на `appointment`/
    `episode`/`subject`-якоре виден только участнику+оператору) — фронт делает из него инбокс.
    Выделенный DM-примитив и приватные круги (`circle:<id>`) — закладки, не сейчас.

## Что уже в ядре (перепроверено) vs пробел

| Машинерия | HTTP сейчас | Пробел |
|---|---|---|
| Protocol/Episode (workflow) | `/protocols`(+state/transition), `/episodes`(+transition) ✓ | — (нужен by-subject read) |
| Ревизия знаний (decay/confirm/refute/supersede) | — (pure в Inference) + `rebuildHypotheses` (Txn) | нет команды ручной записи/правки + HTTP |
| Decision (nextBestAction), Reliability, Query(metaKPI) | `/decision`, `/reliability`, `/query` ✓ | `/query` — только счётчики, не сами знания |
| Knowledge (сами наблюдения/факты) | — | **нет** `/knowledge` (create/update/read строк) |
| Лента опыта / эпизоды / брони клиента | `/experience-events`(ВСЁ), `/episodes`(ВСЁ) | **нет** by-subject |
| Projection (subjectProfile/activeLines/decisionUnit) | — | **нет** HTTP |

## Сверка с концептом (`CXM-концепция-и-ядро.md` §9/§10) — КРЫШКА

Прошёл 9 слоёв + оси (§2) против ядра. **Вся клиент-опытная модель уже в ядре как ДАННЫЕ+ЛОГИКА**
(§9 маппинг авторов концепта, §10 «что в ядре»):

| Концепт | В ядре | HTTP |
|---|---|---|
| Слой I: метапрограммы / убедитель{канал,режим,n} / стратегия реальности / decision-микро | `Trait` (+kDetail субвариант) | **нет** → Ф1 |
| Слой I: decision-МАКРО | `Projection.eventTypeSequence/decisionUnit` | **нет** → Ф3 |
| Слой I.e: соц-решение (роли+порядок) | `DecisionUnit` (у соло-психолога вырожден) | Ф3 (низкий приоритет) |
| Слой II: JTBD / ожидания / (обещания) | `Episode.jtbd` ✓ / `Expectation` / `Promise`(вне scope) | Expect: **нет** → Ф1 |
| Слой III/IV: путь/касания/усилие/использование | `ExperienceEvent`(+eeEffort/type) ✓, `Episode`/`Protocol` ✓ | лента → Ф2 |
| Слой V: пики/концовка/сентимент-траектория | `ee.isPeak/isEnd/sentiment` ✓, `RelationshipState`(STATE+decay) | RelState read → Ф3 |
| Слой VI: счёт доверия / связи | `reliabilityOf` ✓ (`/reliability`), `Edge`(role) ✓ | ✓ |
| Слой VIII: внутренний контур (хэндоффы/SLA/VIII.a) | `InternalHandoff`, INTERNAL-`Subject`, `Trait` | **у соло-психолога ПУСТ** (§11.3) → вне MVP |
| Слой IX: peer/co-support/репутация/self-facing | `ingestPeerEvent`, `coSupportShare`, `contributionOf`, `/v1/me/progress` | ✓ (соц-часть) |
| Оси §2 (тип/источник/уверенность/decay/доказательства) | эпист. конверт `Knowledge`+`Evidence` | createKnowledge должен их нести → Ф1 |

**Вывод:** структурно НЕ ХВАТАЕТ НИЧЕГО — модель полна. Не хватает только **операторской HTTP-
поверхности** (запись/чтение знаний+трейтов+ожиданий+профиля). §10 прямо: бронь/биллинг — СОСЕДНИЕ
адаптеры (у нас пак), UI — край (П4). VIII.a «панель как достучаться до человека» = ФРОНТ поверх
чтения трейтов/убедителя по субъекту (Ф1/Ф3). Внутренний контур (Слой VIII) для соло-психолога
пуст/невидим (§11.3) — вне MVP.

## Фазы

### Ф1 [M] — Knowledge/Trait/Expectation CRUD (ядро «блокнота» + профиль Слоя I) ✅ DONE 2026-07-03
Читать: `Cxm/Knowledge.agda`, `Cxm/Fact.agda`/`Hypothesis`/`Trait` (тонкие конструкторы над конвертом),
`Cxm/Inference.agda` (ревизия pure), `Cxm/Commands.agda`, `Cxm/Api.agda`, `Cxm/Store/Interface.agda`
(`knowledgeT`, `knowBySubject`).
- [x] `createKnowledge` (Txn): ОДИН параметризованный конструктор, несущий все оси §2 (тип/источник/
      confidence/decay/detail/episode). Диспетчер через смарт-конструкторы: FACT→`mkFact` (объективно,
      conf=1000, OBSERVED/IMPORTED); STATED-нефакт→`statedK` ([ВХ]); иначе→`inferredK` ([ПР] INFERRED,
      conf<1000). **Добавлены `inferredK`/`statedK` в `Cxm.Knowledge`** — рантайм-фронт-дор к proof-gated
      `mkInferred` (clamps conf⊓999, снимает proof один раз через `fromWitness (s≤s (m⊓n≤n …))`).
      `requireT subjectsT`. Smoke: FACT со `source:stated,conf:300` → форсится в `observed/1000` ✓.
- [x] **Evidence (§2):** `attachEvidence` (Txn) — `mkEvidence`, оба FK (knowledge+event) через `requireT`.
- [x] `updateKnowledge` (Txn) + `KRevision` ADT: `strengthen/weaken/confirm/refute/supersede/detail`,
      переиспользуя pure-ходы `Cxm.Inference` (refute → REFUTED, conf 0, СТРОКА СОХРАНЕНА). Smoke ✓.
- [x] **Expectation:** `POST /expectations` (`createExpectation`) + `/expectations/by-subject`.
- [x] HTTP: `POST /knowledge`·`/knowledge/update`·`/knowledge/by-subject`·`/knowledge/evidence`·
      `/expectations`·`/expectations/by-subject`; энкодеры `knowledgeJson`/`expectationJson` + enum↔string.
- **DoD:** ✅ записать трейт/гипотезу/факт → by-subject → strengthen/confirm/detail/refute → увидеть
      изменение; expectation создаётся/читается; live-smoke зелёный; адверсарии (чужой субъект 999,
      несуществующее знание 777, evidence на несуществующее событие) → корректный `not_found`. All+guards+
      cxm-server зелёные.

### Ф2 [S] — Карточка клиента: by-subject чтения ✅ DONE 2026-07-03
- [x] `POST /episodes/by-subject` (live+subject), `POST /appointments/by-subject`,
      `POST /experience-events/by-subject` — `filterRows` по `epSubject`/`apSubject`/`eeSubject`
      над `readBase`-снимком (тот же паттерн, что `/knowledge/by-subject`; снимок = реплей WAL).
- **DoD:** ✅ smoke: эпизоды/брони одного клиента изолированы (A↔B не пересекаются); All+guards+
      cxm-server зелёные.

### Ф3 [S] — Богатые чтения профиля (обёртки над `Cxm.Projection`) ✅ DONE 2026-07-03
- [x] `POST /profile` (`subjectProfile` → агрегат: activeKnowledge/activeEpisodes/eventCount);
      `POST /lines` (`activeLines` — живые эпизоды); `POST /decision-unit` (`decisionUnit` —
      decision-consult рёбра, у соло-клиента пуст). Панель VIII.a «как достучаться» = фронт поверх
      `/knowledge/by-subject` (TRAIT-строки, kDetail-субвариант) — данные уже отдаются в Ф1.
- [x] `knownAbout` — через `/knowledge/by-subject` (реальные строки, Ф1).
- [x] **RelationshipState** = STATE-`Knowledge` (kDetail `rel:<traj>/stage=n`), не отдельная таблица;
      `POST /relationship-state/by-subject` отдаёт STATE-полосу субъекта (траектория/стадия — в
      opaque kDetail, фронт декодирует).
- **DoD:** ✅ smoke: profile-агрегат корректен и реагирует на refute (activeKnowledge 3→2); lines
      отдаёт живой эпизод; relationship-state отдаёт только STATE-строку; decision-unit пуст у соло;
      All+guards+cxm-server зелёные. (Сам «умный блокнот»/панель — фронт П4 поверх этих чтений.)

### Ф4 [S, опц.] — Автозаполнение (будущее «многие пункты заполнятся сами») ✅ DONE 2026-07-03
- [x] `POST /inference/rebuild` → `rebuildHypotheses now` (сбросить ACTIVE-гипотезы, пересобрать из
      лога событий; settled REFUTED/CONFIRMED/SUPERSEDED сохраняются). Позже — авто-триггер из ingest.
- **DoD:** ✅ e2e-smoke: mint integration-token → bind identity → `/v1/events` `feature_request` →
      rebuild → появляется `unmet-need` HYPOTHESIS (conf 500, inferred); повторный rebuild
      контент-идемпотентен (ровно одна гипотеза, dedup). All+guards+cxm-server зелёные.

### Ф5 [конфиг/фронт — НЕ ядро] — протоколы workflow + сам кабинет
- [ ] Протоколы «привлечение»/«работа» как ДАННЫЕ (seed/config в паке) — не код ядра.
- [ ] Фронт-кабинет (П4): экраны блокнота/линий/ленты/профиля над эндпоинтами Ф1–Ф4.
      Раскладка фронта — три слоя: `agdelte` (нейтральные UI-примитивы) → `cxm-ui` (общие
      виджеты, привязанные к JSON-контракту: типизир. API-клиент + блокнот/карточка/профиль/тред) →
      сайты (бренд/тема/скины/роутинг). Линия: контракт→`cxm-ui`, бренд→сайт. Правило двух.

## Аудит Ф1–Ф4 (2026-07-03) — соответствие плану/концепции + корректность

**Соответствие:** план Ф1–Ф4 выполнен весь; оси концепта §2 (тип/источник/уверенность/decay/
evidence/episode) несёт `createKnowledge`; слои I(трейты)/II(ожидания)/V(RelationshipState) выставлены.
`Cxm.All`+оба стража+`cxm-server` зелёные; live-smoke каждой фазы + адверсарии.

**Найдено и ИСПРАВЛЕНО (нарушения инварианта §4.1 «FACT ⇒ conf=1000»):**
- F1: `statedK` принимал `EpistemicType` → мог собрать STATED-FACT с conf<1000. Тип сужен до
  `InferredType` — STATED-FACT теперь непостроим (by construction). Verified: typecheck.
- F2: `updateKnowledge` пускал `strengthen/weaken/refute` на FACT → conf 1000→999/0, строка оставалась
  `type:fact`. Гард на командном уровне (`guardT`): conf-мутирующие ревизии на FACT отклоняются
  (ретаить факт — `supersede`, conf сохраняется). Verified adversarially: strengthen/weaken/refute
  FACT → `validation`-ошибка; supersede FACT → ok (1000, superseded); гипотезы ревизятся как прежде.

**Известные ПРОБЕЛЫ ядра (не баги — недоделки/по-дизайну), для отдельного решения:**
1. Нет операторского аппенда в ленту опыта: `completeAppointment` НЕ эмитит `ExperienceEvent`;
   события идут только через `/v1/events` (ingest) — психолог не может вручную залогировать
   касание/сентимент/пик сессии. → кандидат: `POST /experience-events` (operator).
2. `setExpectationStatus` — команда есть, роут НЕ выставлен; GAP «восприятие − ожидание» (суть слоя II)
   не считается проекцией/эндпоинтом. → роут + gap-read.
3. Evidence: только запись (`/knowledge/evidence`), нет чтения цепочки (объяснимость «почему верим»).
4. `conflictSignal` (STATED↔OBSERVED, §4.16) — чистая логика, НЕ подключена к записи (не авто-фича).
5. Decay при чтении: `/knowledge/by-subject`/`/profile` отдают ХРАНИМУЮ уверенность, не now-decayed
   (`applyDecay`/`decayedConfidence` есть, но не применяются на чтении) — расхождение с §1/§4.16.
6. Мульти-тенант: всё на `defaultTenant`, FK-таргеты не проверяются на со-тенантность — ок для флота/
   соло, пробел для общего community-инстанса.
7. Инференс-правил всего 2 (unmet-need/at-risk); TRAIT/STATE правил нет — autofill тонкий (MVP).

## Порядок и границы
```
Ф1 (Knowledge CRUD)   ← ядро блокнота; главная ценность; делать первым
Ф2 (by-subject reads) ← карточка клиента; дёшево, по индексам
Ф3 (profile/lines)    ← богатые чтения; обёртки над Projection
Ф4 (inference)        ← автозаполнение; опц./позже
Ф5 (протоколы+фронт)  ← НЕ ядро (данные + П4)
```
- **НЕ ядро:** сам кабинет/виджеты (фронт П4), протоколы-как-данные, медиа-хостинг (edge),
  клиент-аутентификация (сайт), rate-limit (nginx).
- **Вне scope:** промисы (Р4), выделенный DM-примитив и circles (Р5) — закладки.
- **Инвариант:** после каждой фазы `Cxm.All`/`cxm-server` зелёные; соц-часть не трогаем.
