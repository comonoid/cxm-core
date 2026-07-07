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
- [ ] 1.1 Экран «Записи»: список своих постов (feed от лица владельца-зрителя? нет — нужна
      owner-читалка своих resources; проверить: feed с identity владельца) + «Новая запись».
- [ ] 1.2 Редактор: textarea payload (markdown), visibility/listing-селекторы → `publishV1`.
- [ ] 1.3 Цена: создать offering (`createOffering` c grants на пост) из редактора («продавать
      этот пост за N») — цикл paywall со стороны продавца.
- [ ] 1.4 Витрина: «на полку» (`linkResource` из списка записей; полка сайта — конфиг).

## Ф2. Рендер контента
- [ ] 2.1 markdown-рендер payload'а (`payloadView`-хук виджетов; sanitize!) — БЕЗ mermaid/KaTeX
      сначала; docsify-обвязка — вторым шагом, если markdown-MVP мало.

## Ф3. Зрительская сторона (личный сайт)
- [ ] 3.1 Публичная страница: feed+showcase+thread (v1cfg с cookie-identity), paywall-виджет.
- [ ] 3.2 Полный цикл покупателя: аноним → покупка → регистрация → `mergeSession` → контент его.

## Ф4. Inbox упоминаний
- [ ] 4.1 Серверная читалка mentions (адресат → ноды, где он в addressees) — РОУТА НЕТ,
      добавить (аналог evidence-читалки) → биндинг → экран.

## Ф5. Тема и скин
- [ ] 5.1 Тема кабинета CSS-токенами (custom properties поверх контрактных cxm-* классов).
- [ ] 5.2 ОДИН конкретный медиа-скин прежде движка скинов (решение П4-требований §3).

## Ф6. Позже
- [ ] WS-push (serveWithWs) после poll-версии; anchorKind enum-реестр (ядро, MODULES §6);
      anchorLocator в ConvCtx (под-локации).

## Заметки / решения по ходу
- _(сюда)_
