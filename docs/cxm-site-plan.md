# П4 «морда» — site-psych: кабинет психолога + личный сайт (план)

> Трекер: `- [ ]` не сделано, `- [x]` сделано. Слой 3 (agdelte → cxm-ui → **сайт**).
> Разработка ЦЕЛИКОМ локально: scratch-PG (`scripts/pg-scratch.sh`) + `cxm-server-pg` на :8138 —
> честный деплой только в конце (катовер — ops). Каталог: `~/cxm-core/site-psych/`
> (выделение в отдельный репо — позже, когда продукт назовётся; топология A′).
>
> **DoD П4 (из cxm-platform-plan §П4):** сценарий психолога от логина до проданного поста —
> в браузере. NB: пункт «cxm-sdk.js + виджеты» ЗАКРЫТ слоем cxm-ui (типизированные Agda-виджеты
> вместо JS-SDK) — шесть аудитов, README для авторов сайтов.

## Механика композиции (решение)
Сайт — один agdelte-app: `Model` сайта СОДЕРЖИТ модели виджетов, `Msg` оборачивает их Msg,
`update`/`cmdOf` делегируют (`mapCmd`), template встраивает виджеты через `zoomNode proj wrap`.
Виджеты не трогаем — используем их публичные Model/Msg/updateModel/cmdOf/template (embedding-
паттерн из cxm-ui/README).

## Ф0. Каркас: логин → кабинет
- [x] 0.1 Либа `site-psych` (depend: stdlib+agdelte+cxm-ui, реестр ~/.agda/libraries),
      `SitePsych/Main.agda`: стадия Login (форма → `Client.login`) → стадия Cabinet
      (`ClientCard` через zoomNode; Card.Model переинициализируется с JWT после логина).
      Сверка контракта при старте (`Client.health` ↔ `expectedContract`) — красный баннер при дрейфе.
- [x] 0.2 Дев-сервер (`site-psych/dev/serve.mjs` по образцу cxm-ui: статика+прокси на :8138,
      no-store) + `index.html` (маунт Main.app).
- [x] 0.3 Смоук (`dev/smoke.mjs`, happy-dom + живой сервер): логин с формы → кабинет виден →
      ростер грузится. `npm test`/`npm run dev` в site-psych/package.json.

## Ф1. Блог: написать/редактировать/цена
- [x] 1.1 Экран «Записи»: список своих постов + «Новая запись». РЕШЕНО ПРОВЕРКОЙ: owner-читалка
      НЕ нужна — `feedViews` включает автора без фоллова (`fromFeedAuthor: a ≡ᵇ viewer`),
      экран = cxm-ui Feed с identity владельца (V1Cfg из минта токена при логине,
      identity = "user_id"/login). Вкладки кабинета: «Клиенты» | «Записи».
- [x] 1.2 Редактор: textarea payload (markdown — рендер в Ф2), видимость public|entitled|private
      → `publishV1`. listing НЕ селектор, а политика сайта: entitled ⇒ listing=public
      (storefront-тизер S7), иначе серверный дефолт.
- [x] 1.3 Цена: при «платная»+цена>0 после публикации `createOffering` (kind 1, ₽→коп, RUB,
      metadata `{"grants":[{"kind":"resource","id":N}]}`) — цикл paywall со стороны продавца.
- [x] 1.4 Витрина: «на полку» (`linkResource(полка, запись, rank 1, бессрочно)`); id полки —
      поле ввода (листалки полок у сервера нет; полка-конфиг — когда появится не-scratch деплой).
      Смоук: 16/16, самодостаточен (сеет владельца/клиента/полку сам); анонимный showcase
      отдаёт платную запись locked-тизером, автору — открыта (authorSeesOwn).

## Ф2. Рендер контента
- [x] 2.1 markdown-рендер payload'а — docsify-СТЕК (решение пользователя 2026-07-10: «markdown
      надо docsify — он умеет всё»; самописный Agda-парсер написан и ВЫКИНУТ в тот же день):
      custom-element `<site-markdown data-md=…>` (`dev/md-element.mjs`) рендерит marked
      (движок docsify) + DOMPurify (санитайз: script/onload/javascript:-href вырезаются;
      ссылкам принудительно rel=noopener+target=_blank). Agda-слой лишь проносит сырой payload
      атрибутом (`payloadView`-хук Feed) — agdelte/cxm-ui не тронуты. Вендорено в `dev/vendor/`
      (marked 12.0.2 esm, dompurify 3.1.6 esm, docsify 4.13.1 — на Ф3). Смоук 21/21.
- [x] 2.2 docsify-СТРАНИЦЫ (2026-07-11): `dev/pages.html` — docsify владеет своей страницей
      (динамика остаётся на public.html, кросс-ссылки в обе стороны: nav «О подходе» ↔
      sidebar «← Записи»); раскладка НА НАШИХ токенах (родные темы docsify не подключены —
      тёмная тема бесплатно); `pages/` — markdown-страницы владельца (README «о подходе»
      с mermaid-диаграммой, uslugi с ценами из каталога), правятся БЕЗ пересборки.
      Плагин: контент-схемы — ТА ЖЕ applyContentSchemes из md-element (экспортирована,
      routes параметром: post:N → public.html#/post/N; sidebar-ссылки не трогаются,
      внешние — noopener+_blank) + ```mermaid → живая диаграмма (mermaid@9 UMD вендорен).
      KaTeX — ОТЛОЖЕН (тянет пачку шрифтов; по потребности). Вики позже — этим же способом.
      Смоук 79/79 ×2 + HTTP-отдача всех ассетов проверена.
- [x] 2.3 Контент-схемы (решения 2026-07-10) — ссылки и медиа в markdown СУЩНОСТНЫЕ, не URL
      (payload рендерится на многих поверхностях: кабинет, docsify-страница Ф3, синдикация
      на площадку с другим доменом (В3 deep-link), вики — абсолютные URL протухают):
      * `[t](post:N|shelf:N|thread:N)` → routes-таблица md-element (`#/post/N`…; цели —
        роуты Ф3); внутренние ссылки БЕЗ target=_blank, внешним — noopener+_blank.
        Ссылка на платный пост = paywall-тизер на целевой странице (S7) — продажа из текстов.
      * `![](video:N)` → НАТИВНЫЙ `<video controls src=/media/N>` (П4-требования §3: скин Ф5 —
        SVG-хром вокруг нативного; `/media/:id` — контракт доставки, серверная половина П4c).
      * `![](youtube:ID)` → iframe СТРОГО по шаблону youtube-nocookie/embed/<ID> (произвольные
        iframe DOMPurify режет как резал; ID валидируется).
      ALLOWED_URI_REGEXP расширен этими схемами. На docsify-странице Ф3 та же трансформация
      становится docsify-плагином (и позже — в вики). Относительные пути в контенте не поощряем.

## Ф3. Зрительская сторона (личный сайт)
- [x] 3.1 Публичная страница: `SitePsych.Public` + `dev/public.html` (конфиг: ?itok=&shelf=,
      visitor-identity генерится в localStorage). Роутинг — agdelte `onUrlChange` (hash),
      маршруты = цели контент-схем Ф2.3: `#/` — витрина полки сайта + paywall, `#/post/N` —
      тред записи (root = запись; locked → S7-тизер) + paywall. Виджеты Showcase/Thread/
      Paywall embedding-паттерном, payload — `<site-markdown>`. NB: листинг главной — SHOWCASE,
      не feed (feed follow-based, анониму пуст — витрина и есть публичная лента сайта).
      Смоук 33/33, в т.ч. цикл: аноним видит тизер → покупает на странице записи → webhook →
      контент открыт (entitlement на provisional-субъекте cookie-identity).
      Хвост 3.1: docsify-страницы (`docsify.min.js` в vendor) + docsify-плагин контент-схем.
- [x] 3.2 Полный цикл покупателя: аноним → покупка → регистрация → merge → контент его.
      Дыра контракта (сайт не знает числовой id provisional-субъекта; merge живьём не гонялся)
      закрыта ШВОМ ПО-ДРУГОМУ (лучше выдачи id наружу): /v1/merge-session принимает provisional
      и IDENTITY-ПАРОЙ (`provisional_channel`/`provisional_id`, дефолт "cookie") — резолв
      серверный; уже-слитая пара → идемпотентный no-op (гард: mergeV prov prov зациклил бы
      sCanonical на себя). Клиент: `mergeSessionBy` в CxmUI.Client (V1Cfg вызова несёт
      LOGIN-identity; сайт зовёт ПОСЛЕ /auth/login — login доказывает контроль канала).
      Сайт: блок «Сохранить доступ» (register→login→merge одной кнопкой; 409 не рвёт цепочку).
      Смоук 36/36 ×2 (идемпотентность = гард самослияния), адверсарий: чужая cookie — тизер.
      NB сборки сервера: LIBRARY_PATH=<nix zlib>/lib перед cabal build (грабля POSTGRES-SPIKE).

## Ф4. Inbox упоминаний
- [x] 4.1 Серверная читалка: `/v1/mentions` (readMentions: узлы, где viewer в addressees;
      feed-shaped cvEnc-строки, live+canList, locked=¬canAccess, newest-first; аноним — []).
      Биндинг `mentionsV1` + виджет `CxmUI.Inbox` (реюз PUBLIC-кусков Feed, переопределён
      только cmdOf — источник). Кабинет: третья вкладка «Упоминания». Смоук 39/39 ×2,
      адверсарии: не-адресат и аноним не видят.
      ПОПУТНО НАЙДЕН И ЗАКРЫТ КОНТРАКТ-БАГ: addressees на проводе — «[1,2]»
      (CxmUI.Client.showIds), а сервер парсил Storage.decodeIds'ом ([{"id":N}]-строки) —
      mentions НЕ СОЗДАВАЛИСЬ никогда (аудит-5 №3 привязал, но живьём не гонял). Сервер
      переведён на толерантный parseNats (в духе Cxm.Fulfilment).

## Ф4b. Фронт услуг (добавлена и закрыта 2026-07-11)
- [x] 4b.1 `SitePsych.Booking` — экран записи на публичной странице, маршрут `#/book`
      (+нав-ссылка «Записаться»): сетка свободных слотов (человеческое время — custom-element
      `<site-ts>`, тот же шов, что markdown) → выбор → имя+email → бронь → «вы записаны»
      → сетка перечитана (занятый слот исчез). Select intro/session. Wire — `PsychCxm.Client`
      (первый потребитель пак-SDK в слое 3; site-psych.agda-lib += cxm-pack-psych);
      Cmd-обвязка в сайте. Смоук 60/60 ×2.
      Попутные фиксы: (1) agdelte Json FFI — COMPILE JS прагмы encodeToString/encodeWith
      не принимали стёртый {A : Set} (JS-бэкенд передаёт null; GHC стирал молча — вскрыл
      первый JS-потребитель PsychCxm.Client); (2) урок рантайма: бинды ВНУТРИ
      foreachKeyed-строк не живут (строки пере-рендерятся по ключу) — реактивное состояние
      показывать узлами ВНЕ строк (bk-chosen); (3) подтверждение записи — отдельное поле
      done (перезагрузка сетки затирала общий status — гонка, ловилась вторым прогоном).

## Ф5. Тема и скин
- [x] 5.1 Тема CSS-токенами: `dev/theme.css` (токены var(--s-*) + [data-theme=dark]-пресет)
      поверх контрактных cxm-*/site-* классов; обе страницы переведены на токены, public
      переопределяет свой --s-bg (механика брендинга — так же будет у клоунов). Переключатель
      `dev/theme.mjs` (data-theme + localStorage; тестируемый юнит) + кнопка ◐. Хранение
      темы как Resource rKind="theme" — закладка §4, по потребности. Бейджи знаний
      (cxm-badge-*) пока пастель-хардкод — токенизировать при первом реальном брендинге.
- [x] 5.2 ПЕРВЫЙ конкретный медиа-скин «calm» (прежде движка): `dev/skins/calm.mjs` —
      «скин как данные»: декларативный бандл {SVG-хром, CSS-раскладка}; md-element
      оборачивает НАТИВНЫЙ <video> (.site-player + svg.skin-chrome, pointer-events:none —
      controls живые); цвета скина — токенами темы (живёт в обеих темах). Движок/шаринг
      скинов («личный сайт за деньги») — после первого реального второго скина.
      Смоук 75/75 ×2.

## Ф6. Позже
- [ ] WS-push (serveWithWs) после poll-версии; anchorKind enum-реестр (ядро, MODULES §6);
      anchorLocator в ConvCtx (под-локации).

## Заметки / решения по ходу
- 2026-07-11 ДОЛГИ СЛОИСТОСТИ (аудит размещений; стражи+тесты зелёные: neutrality OK,
  layering OK, cxm-ui 28/28+29/29, site-psych 60/60): (1) mentionViews в сервере, а братья
  feedViews/threadViews — в Cxm.Social: при разморозке ядра перенести; (2) гард самослияния
  merge — в сервере, место ему в mergeSessionV; (3) md-element.mjs (+<site-ts>) — generic
  движок в site-psych: перед П7 поднять в общий слой (иначе клон начнётся с копипасты).
- 2026-07-10 (Ф1): /v1-конфиг кабинета = минт integration-token при каждом логине
  (`mintIntegrationToken` в `cmdOf GotJwt`); токены копятся по токену на логин — ok для дев,
  до продакшена решить: переиспользование/ревокация (кандидат в Ф6). `cmdOf` в agdelte видит
  ПРЕ-батч модель — конфиги команд строятся из самого сообщения (jwt/token), не из полей модели.
- 2026-07-10: услуги (запись/пакеты, `/psych/*` на PG-сервере) — ОТДЕЛЬНАЯ ветка **П4b**
  в cxm-platform-plan (параллельна Ф1–Ф3); фронт-экраны записи добавятся сюда фазой после неё.
- 2026-07-10: решена **вторая вертикаль** (мастера клоунады) = клон pack+site с psych
  (платформа-план §П7). Правило на время П4: фичу сортировать тестом «нужно ли клоунам?» —
  одинаково → cxm-ui/ядро (по умолчанию), другой словарь → пак, вид/тексты → сайт.
