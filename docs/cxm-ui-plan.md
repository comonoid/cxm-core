# cxm-ui — план (слой 2: agdelte → **cxm-ui** → сайты)

> Трекер: `- [ ]` не сделано, `- [x]` сделано. Живёт рядом с остальными планами (`docs/`).
> Слой контракт-привязанных виджетов CXM. Говорит по HTTP/JSON с `cxm-server-pg`, зависит от
> `agdelte` (не от Agda-ядра `cxm`). См. [[cxm-frontend-layering]], `docs/pg-store-plan.md`.

## Контекст (что уже стоит, 2026-07-03)
- `cxm-ui/` — либа (`cxm-ui.agda-lib`, depend stdlib+agdelte), `package.json` (`agda --js` + node-тест).
- `CxmUI/Contract.agda` — 7 view-типов + декодеры (Knowledge/Profile/Expectation/Experience/Episode/
  Evidence/Subject), тайпчекается; `test/contract.test.mjs` — декодеры против реального JSON.
- Framework готов: реактивная модель `Model/Msg/update/view` (без VDOM), `Cmd/Task.httpPostH`
  с заголовками (→ `Authorization: Bearer`), Json-FFI слот-фикс сделан.
- **⚠ Контракт устарел** — писался под Ф1–Ф4, сервер с тех пор разросся (auth, ~35 кабинетных роутов,
  `/v1` feed/thread/showcase, promise-market, платежи, `rebuild-inference`). Первый шаг — ре-базлайн.

## Граница слоёв
- **В `cxm-ui`** (привязано к JSON-контракту): view-типы + декодеры, типизированный API-клиент
  (auth+Bearer), реактивные виджеты. Бренд-нейтрально.
- **НЕ в `cxm-ui`** (→ сайты): тема/скины/аватары, роутинг, копирайт, вертикальные экраны,
  композиция под конкретный продукт.

## Приоритет (решение)
Порядок Ф2 vs Ф3: **кабинет-первым** (рекомендация — ближе к текущему контракту, MVP «одного
психолога»); community (соц-сторона) — следом. _(изменить, если нужно наоборот)_

---

## Ф0. Ре-базлайн скаффолда
- [x] 0.1 Собрать `agda --js CxmUI/Contract.agda` + `npm run test:contract` — зелёный старт (9/9 ✓)
- [x] 0.2 Снять фикстуры реального JSON с живого `cxm-server-pg` → `cxm-ui/test/fixtures/reads.json`
- [x] 0.3 Выверка `Contract.agda` против факта — **★ НАХОДКА: read-поверхность сервера БЕДНАЯ.**
      - read-эндпойнтов меньше, чем думал контракт: **НЕТ** `/profile`, `/episodes/by-subject`,
        `/expectations/by-subject` (они были под WAL-сервер) → `profileDec`/`episodeDec` пока «в воздухе».
      - существующие reads возвращают ОБРЕЗАННЫЕ view: `/subjects`→`{id,name}`, **`/knowledge/by-subject`→
        `{detail}` только** (энкодер `enc k = {"detail":…}` — тип/статус/уверенность отброшены),
        `/appointments/by-subject`→`{id,start,duration,status}`. Rich-view-типы контракта (эпист-бейджи!)
        серверу пока НЕ соответствуют.
      - **Вывод:** кабинетные виджеты (Ф2, особенно блокнот с бейджами и карточка с эпизодами)
        ЗАБЛОКИРОВАНЫ бедным read-слоем сервера. Нужна Ф0.4 ↓ (это правка `cxm-server-pg`, не cxm-ui).

## Ф0.4. Обогащение read-поверхности сервера (ПРЕРЕКВИЗИТ Ф2; это работа в `cxm-server-pg`)
- [x] 0.4.1 `listKnowledge`-энкодер → полный KnowledgeView (id/subject/type/source/confidence/validFrom/
      validTo/decay/status/detail/episode) — питает блокнот+бейджи. Live ✓, `knowledgeDec` совпал (9/9).
      _(confidence — сырой; decay-on-read Д5 отложен: у клиента есть decay+validFrom → может сам)_
- [x] 0.4.2 `POST /episodes/by-subject` + EpisodeView-энкодер (id/subject/protocol/state/jtbd; skip soft-del). Live ✓ = `episodeDec`
- [x] 0.4.3 `POST /expectations/by-subject` + ExpectationView-энкодер (id/subject/topic/source/level/status/createdAt). Live ✓ = `expectationDec`
- [ ] 0.4.4 (опц., НЕ блокер Ф2) обогатить `/subjects` до полей карточки / `/profile`-агрегат — по мере нужды
- [x] 0.4.5 Фикстуры пересняты (`reads.json`); декодеры Contract уже совпали — contract-тест 9/9 зелёный
      **⇒ Ф2 (кабинет) РАЗБЛОКИРОВАН: knowledge/episodes/expectations/appointments read'ы дают полные view.**

## Ф1. Типизированный API-клиент (`CxmUI/Client.agda`)
- [x] 1.1 Инфра: `Cfg`(base/jwt) + `CallErr`(http/server/decode) + `envelope` (data/error-конверт) +
      `authHdr` (Bearer) + `postJson`/`getJson`; `login`→JWT. `envelope` публична (node-тестируема).
- [x] 1.2 Кабинетные reads: `roster` + `knowledgeOf`/`episodesOf`/`expectationsOf`/`appointmentsOf`
      — каждый `Cfg → ℕ → (Result CallErr <View> → M) → Cmd M`. (writes — добавлю по мере виджетов Ф2.)
- [x] 1.3 `/v1` reads — Contract: `ContentView` (id/author/createdAt/locked/payload; showcase =
      той же формы) + `ThreadNodeView` (depth+content), декодеры. Client: `V1Cfg` (base +
      x-integration-token + identity_channel/id — у /v1 СВОЙ auth, не Bearer) + `feed`/`thread`/
      `showcase`. Фикстуры сняты с живого /v1 (publish×2+follow+comment): открытый пост, locked-
      тизер (payload зачищен), тред depth 0/1 с эмодзи. Тесты client 12/12. ★ Сервер-обогащение
      (аналог Ф0.4): cvEnc/tvEnc были {id,locked,payload} — добавлены author+createdAt (фид без
      автора/времени не рендерится); пересобран, live ✓. ★ Находка: `linkResourceV` есть в
      CommandsV, но HTTP-роута нет ⇒ витрину нельзя наполнить по HTTP — пререквизит Ф3.3.
      ★ Тред-нюанс: /v1/comment попадает в тред только с явным `parent` (anchor ≠ parent).
- [x] 1.4 Golden-тест клиента (`test/client.test.mjs`, **6/6**): `envelope`+декодеры против
      ENVELOPED-фикстур (`{"data":…}`) + error-путь (`{"error":…}`→serverErr). `npm test`: 9/9 + 6/6.
      Добавлены view-типы в Contract: `RosterView` (тонкий /subjects), `AppointmentView`.

## Ф2. Кабинетные виджеты (операторская консоль)
- [x] 2.1 **Карточка клиента** — `CxmUI/ClientCard.agda`: реактивный Model/update/cmd/view/app
      (`clientCardApp cfg`). Ростер → выбор субъекта → `batch` загрузки knowledge/episodes/appointments.
      Тайпчек ✓, `agda --js` → `.mjs` ✓ (визуал — вручную в Ф4-харнессе). Ф2.1+2.2-дисплей одним виджетом.
- [x] 2.2 **Эпист-бейджи** (дисплей) — знания рендерятся с бейджами type (fact/hypothesis/state/trait) +
      status + ‰confidence + opaque detail (CSS-классы `cxm-badge-<type>`/`cxm-status-<status>` для сайта).
- [x] 2.3 Действия ревизии — сервер: добавлен `POST /knowledge/revise` {knowledge, kind, amount?, detail?}
      (`parseRev`→KRevision→`updateKnowledgeV`). Клиент: `reviseKnowledge cfg kid kind`. Виджет: кнопки
      confirm/refute/supersede в knowRow (param-free); успех перезагружает знания. **Live ✓** (create→
      confirm→status `active`→`confirmed`). **Находка live: okUnit заворачивается в `{"data":{"ok":true}}`**
      (не bare) — `envelopeUnit` чинён (идёт через `envelope`), тест на РЕАЛЬНОЙ форме. Остаток: param-
      кнопки strengthen/weaken/redetail (нужен ввод числа/текста в UI).
- [x] 2.4 Блокнот: кнопка «перестроить вывод» — `Rebuild` (читает `selected` в cmd) → `Client.rebuildInference`
      (`POST /knowledge/rebuild-inference`, обрабатывает `{"ok":true}` через `envelopeUnit`) → перезагрузка знаний.
      Client+ClientCard компилятся; `envelopeUnit` тест 2/2 (ok+error). Роут на сервере уже был.
- [x] 2.5 **Панель VIII.a** — Contract: `WorkStrategyView` + `workStrategyDec` (kind-гейт
      `"work_strategy"`, все параметры `optionalField` — пустая стратегия валидна) +
      `parseWorkStrategy : String → Maybe` (чистый вход панели/тестов). Виджет: секция
      «Как достучаться» (`cxm-ws-panel`), `parseWorkStrategy (kvDetail k)` по знаниям выбранного
      субъекта → фраза «синхронно · сначала детали · хэндофф полон: …»; refuted/superseded скрыты
      (история — в блокноте), панель через `when` показывается лишь когда есть что (прогрессивное
      раскрытие §VIII.a). Тесты +5 (contract 14/14): full/bare/чужой kind/не-JSON/end-to-end
      через knowledgeDec. NB: у kDetail НЕТ серверного энкодера (opaque, operator-authored) —
      конвенция типизируется именно здесь, синтетические строки в тесте легитимны.
- [x] 2.6 **Expectation-gap** — секция «Ожидания» в карточке: `expectationsOf` в batch-загрузке, `xpRow`
      с gap-сигналом (met/unmet/unknown, класс `cxm-exp-<status>`) + topic + уровень. Компилится.

## Ф3. Сообщество / соц-виджеты (community)
- [x] 3.1 **Лента** — `CxmUI/Feed.agda`: `feedApp v1cfg` (Model/update/cmd/view), пост = автор +
      t + payload verbatim (opaque JSON — парсит/стилизует сайт); locked → `cxm-post-locked` +
      тизер-хром «🔒», payload у сервера уже зачищен. Live-смоук 9/9 (сид publish×2+follow через
      /v1, зритель видит открытый пост и тизер БЕЗ секрета). Харнесс: запись «Лента» (сам минтит
      integration-token после логина), дев-стили cxm-post*.
- [x] 3.2 **Тред/разговор** — `CxmUI/Thread.agda`: `threadApp v1cfg root`, пре-упорядоченный
      список нод сервера (depth 0 = корень, дети createdAt-asc), `cxm-depth-<n>` для отступа
      (сайт превращает в рельсу), locked → тизер-стрип «🔒», payload зачищен. Live-смоук 12/12
      (корень + публичный ответ depth-1 + приватная реплика-тизер). Харнесс-запись (root через
      prompt), дев-стили cxm-thread/depth.
- [x] 3.3 **Витрина** — сервер-пререквизит закрыт: `POST /resources/link`/`/resources/unlink`
      (кабинет, Bearer) поверх существовавших linkResourceV/unlinkResourceV. Виджет
      `CxmUI/Showcase.agda`: `showcaseApp v1cfg shelfId`, строки feed-формы (cxm-post*), rank-asc
      серверный, протухший validTo-слот исчезает проекцией. Live-смоук 14/14 (порядок Б-до-А по
      rank, expired слот отсутствует). Фикстура showcase непустая (полка 60), client-тест 12/12.
      Кураторские записи — кабинет владельца, НЕ зрительский виджет.
- [x] 3.4 **Paywall/покупка** — сервер: `POST /v1/offerings` (live-офферы тенанта: id/kind/price/
      currency/metadata — fulfilment-план это данные, не секрет) + `POST /v1/purchase` (PENDING-
      платёж по СЕРВЕРНОЙ цене, клиент сумму не шлёт; успех — только вебхук `/payments/succeed`,
      admin:use). Contract: `OfferingView`+`idDec`. Client: `offeringsV1`/`purchase`. Виджет
      `CxmUI/Paywall.agda`: список офферов (№ + цена в мажорных единицах `showAmount`) + «Купить» →
      «платёж #N создан…»; контент открывается на следующем чтении (entitlement) — сайт обновляет
      feed/thread. Live-смоук **16/16**: entitled-пост как тизер → покупка В ВИДЖЕТЕ → админ-succeed
      → пост открылся в ленте. Смоуку нужен PSYCH_ADMIN_LOGIN/PASSWORD (см. шапку dev/smoke.mjs).

## Ф4. Дев-харнесс + полировка
- [x] 4.1 Дев-харнесс (`cxm-ui/dev/`, НЕ продуктовый сайт): `serve.mjs` (статика dev/+_build/+
      agdelte-runtime + same-origin ПРОКСИ прочих путей на cxm-server-pg — CORS серверу не нужен,
      Cfg base="" как в проде) + `index.html`/`harness.mjs` (storybook-каталог: логин→JWT в
      sessionStorage → runReactiveApp; новый виджет = строка в WIDGETS) + `dev/smoke.mjs` —
      автоматическая половина «DOM вручную»: happy-dom + РЕАЛЬНЫЙ fetch к живому серверу,
      сам сидит данные, кликает Загрузить→субъект, ждёт round-trip'ы — 7/7 ✓ (вкл. панель VIII.a
      с живой фразой). `npm run dev` / `npm run test:smoke` (нужен живой сервер на :8138).
      ★ Смоук вскрыл 2 дрейфа: (1) live `/auth/login` отдаёт `{"data":{"token":…}}`, а Ф1.1
      ждал голый `{"token":…}` — `Client.login` переведён на `envelope`, тест на реальной форме
      (client 9/9); (2) agdelte runtime `agdaHeadersToObj` умел только callable-пары, а Agda 2.9
      --js эмитит объектную форму `{"_,_":…}` → httpGetH/httpPostH с заголовками падали ИЗ Agda
      (тест auth-http.test.js строил пары руками в JS и дрейф не ловил) — починено по образцу
      events.js onKeys; agdelte auth 13/13 + dom 66/66 без регрессий.
- [x] 4.2 Единый стиль — `CxmUI/Widget.agda`: `errText` (одна формулировка ошибок вместо 5 копий
      errStr), `emptyOr` (конвенция пустых состояний: «… пуста/нет» в статус-строке после пустой
      загрузки), `toolbar` (единая форма кнопка+статус, классы cxm-toolbar/cxm-load/cxm-status —
      сайт стилизует один раз). Все 5 виджетов переведены; лоадеры и так были едины («загрузка …»).
      Смоук 17/17 (+ пустая витрина → «витрина пуста»).

---

## Тестирование (метод из памяти; DOM — вручную)
- Чистая логика (update/форматтеры/бейдж-маппинг) → `agda`-тайпчек / refl.
- Декодеры + клиент → `agda --js` → `node test/*.mjs` против **реального** JSON сервера (golden-фикстуры).
- DOM-рендер → только браузер (дев-харнесс Ф4.1), визуально — вне автотестов.

## Заметки / решения по ходу
- Ф2.3-хвост ЗАКРЫТ (2026-07-07): `Client.reviseKnowledgeBy` (amount) + кнопки «▲ +50»/«▼ −50»
  (фикс-шаг вместо ввода числа) + **redetail-форма** («✎ детали» → преднаполненный input →
  `Client.reviseDetail`; текст уходит через новый `escJson` — кавычки/бэкслеши/переводы строк;
  escJson применён и к login). Смоук 21/21: strengthen кликом 500→550 в DOM; redetail с
  кавычками в тексте сохранён, ряд обновился, форма закрылась.
- **БАГ РАНТАЙМА НАЙДЕН И ПОЧИНЕН (2026-07-07, в agdelte):** первоначальный диагноз «onClick
  мёртв у вложенных кнопок» был ЛОЖНЫМ (артефакт испорченного sed-ами репро) — клики работали
  всегда. Настоящий баг: **foreachKeyed не перерисовывал ряд с неизменным ключом при изменившемся
  item** (ряды пекут данные в статический text при рендере; updateScopeImmediate обновлял только
  bindings) — ревизия проходила на сервере, но DOM показывал старый статус/уверенность. Фикс:
  (1) `updateKeyedList` → `rerenderEntry` при `!deepEqual(entry.item, newItem)` в обеих ветках
  (same-keys и reuse); (2) `deepEqual` научен объектной Scott-форме Agda 2.9 (`{"ctor":fn}`) и
  массивам (раньше объекты/массивы сравнивались по ссылке ⇒ либо всегда-перерендер, либо стейл).
  Весь сюит agdelte зелёный (dom 66, runtime, smoke 313, video 129, …); cxm-ui смоук 18/18.
  Урок: смоук-скрипт не редактировать sed-цепочками — переписывать целиком.
