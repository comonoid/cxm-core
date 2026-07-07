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
- [ ] 0.4.2 Добавить `POST /episodes/by-subject` (нужен карточке клиента) + EpisodeView-энкодер
- [ ] 0.4.3 Добавить `POST /expectations/by-subject` (нужен expectation-gap) + ExpectationView-энкодер
- [ ] 0.4.4 (опц.) обогатить `/subjects` или добавить `POST /subjects/get` до нужных карточке полей;
      (опц.) `/profile`-агрегат, если решим агрегировать на сервере
- [ ] 0.4.5 Перезаснять фикстуры с обогащённого сервера; выверить/поправить декодеры Contract.agda → зелёный contract-тест

## Ф1. Типизированный API-клиент (`CxmUI/Client.agda` + под-модули)
- [ ] 1.1 `auth`: register/login → JWT; authed-хелпер (`httpPostH` + Bearer); обработка 401/403/409
- [ ] 1.2 По-эндпойнтные вызовы кабинета (subjects/knowledge/episodes/appointments/expectations/promises/accounts/payments) — каждый → декодированный view или доменная ошибка
- [ ] 1.3 По-эндпойнтные вызовы `/v1` (feed/thread/showcase/publish/follow/comment)
- [ ] 1.4 Golden-тест клиента: `agda --js` → node против снятых фикстур

## Ф2. Кабинетные виджеты (операторская консоль)
- [ ] 2.1 **Карточка клиента** — субъект + эпизоды + брони + знания (композит)
- [ ] 2.2 **Умный блокнот знаний** — эпист-бейджи (FACT/HYPOTHESIS/STATE/TRAIT + статус/уверенность/decay)
- [ ] 2.3 Блокнот: действия ревизии (strengthen/weaken/confirm/refute/supersede/redetail)
- [ ] 2.4 Блокнот: кнопка «перестроить вывод» (`POST /knowledge/rebuild-inference`)
- [ ] 2.5 **Панель VIII.a** — декодер `kDetail` рабочих стратегий (work_strategy trait) → читаемая панель
- [ ] 2.6 **Expectation-gap** — ожидания vs факт, статусы

## Ф3. Сообщество / соц-виджеты (community)
- [ ] 3.1 **Лента** (feed) — контент авторов, за кем следит зритель; newest-first
- [ ] 3.2 **Тред/разговор** — список чанков; teaser-стрип у locked
- [ ] 3.3 **Витрина** (showcase) — ранги + validTo-окно
- [ ] 3.4 **Paywall/покупка** — entitlement-gated контент + кнопка покупки

## Ф4. Дев-харнесс + полировка
- [ ] 4.1 Дев-страница (НЕ продуктовый сайт) — рендер виджетов в браузере для визуальной проверки (storybook-подобный каталог)
- [ ] 4.2 Единый стиль: ошибки, лоадеры, пустые состояния

---

## Тестирование (метод из памяти; DOM — вручную)
- Чистая логика (update/форматтеры/бейдж-маппинг) → `agda`-тайпчек / refl.
- Декодеры + клиент → `agda --js` → `node test/*.mjs` против **реального** JSON сервера (golden-фикстуры).
- DOM-рендер → только браузер (дев-харнесс Ф4.1), визуально — вне автотестов.

## Заметки / решения по ходу
- _(сюда — портовые решения, находки, отклонения от плана)_
