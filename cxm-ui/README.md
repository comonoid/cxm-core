# cxm-ui — контракт-привязанные виджеты CXM (слой 2)

Слоёвка фронта: **agdelte** (нейтральные реактивные примитивы) → **cxm-ui** (этот пакет:
типизированный API-клиент + виджеты, привязанные к JSON-контракту `cxm-server-pg`) →
**сайт** (репо на продукт: тема, роутинг, копирайт, композиция). Правило раздела: привязано
к API-контракту → сюда; привязано к бренду/продукту → на сайт. Зависимости: stdlib + agdelte;
Agda-ядро `cxm` НЕ импортируется (страж G4 в `cxm/scripts/check-layering.sh`) — слой говорит
с сервером только по HTTP/JSON.

## Модули

| Модуль | Что это |
|---|---|
| `CxmUI.Contract` | View-типы + JSON-декодеры, зеркалящие серверные энкодеры (контракт закодирован ОДИН раз) |
| `CxmUI.Client`   | Типизированный клиент: `Cfg` (Bearer) — кабинет, `V1Cfg` (integration-token) — /v1; reads + writes |
| `CxmUI.Widget`   | Общая лексика виджетов: `errText`, `emptyOr`, `toolbar`, `showAmount`, `verbatimPayload` |
| `CxmUI.Text`     | ВСЕ пользовательские строки (единая точка локали) |
| `CxmUI.ClientCard` | Операторская карточка: ростер → знания (бейджи/ревизии/«почему»/добавить) + эпизоды/брони/ожидания + панель VIII.a |
| `CxmUI.Feed` / `Thread` / `Showcase` | Соц-читалки: лента подписок, разговор (+форма ответа), витрина |
| `CxmUI.Paywall`  | Покупка: офферы → `/v1/purchase` (PENDING по серверной цене; успех — вебхук) |
| `CxmUI.UpdateTest` | refl-тесты чистой update-логики (гонки/busy/toggle) |

## Быстрый старт (сайт)

```agda
open import CxmUI.Client using (mkCfg; mkV1Cfg)
open import CxmUI.ClientCard using (clientCardApp)
open import CxmUI.Feed using (feedApp; feedAppWith)

cabinetApp = clientCardApp (mkCfg "" jwt)              -- base "" = same-origin
communityFeed = feedApp (mkV1Cfg "" itok "cookie" sid) -- /v1: свой auth, не Bearer
```

Монтаж: `runReactiveApp({app: Mod.feedApp(cfg)}, el)` из `agdelte/runtime/reactive.js`
(или `data-agdelte` + reactive-auto).

## Хуки для сайта

- **payload-рендерер**: payload контента — opaque JSON сайта; дефолт рендерит verbatim.
  Свой парсер/вёрстка: `feedAppWith myPayloadView cfg limit` (аналогично thread/showcase).
- **Embedding**: `Model`/`Msg`/`updateModel`/`cmdOf`/row-билдеры ПУБЛИЧНЫ — сайт собирает
  свой template и перехватывает Msg (напр., `Bought (ok pid)` из Paywall, или читает
  `lastPayment` из модели после апдейта). `paywallAppWith cfg extIdPrefix` — per-purchase
  ext_id = `prefix-N` для корреляции с платёжным провайдером.
- **limit** (feed/thread/showcase): 0 = всё; N = верхушка серверного порядка. Это «тихий
  срез» без hasMore — настоящая пагинация (курсор) будет отдельным контрактом.
- **CSS**: виджеты бренд-нейтральны, стилизуются по контрактным классам `cxm-*`
  (toolbar/load/status; post/…-locked/…-teaser; thread-node/depth-N; know/badge-<type>/
  status-<status>/conf/rev-*; ws-panel; exp-<status>; offer/buy; edit-detail; evidence-panel;
  add-obs; reply). Дев-стили-образец: `dev/index.html`.

## Тесты и метод

- Чистая логика → refl (`npm run test:update`).
- Декодеры/клиент → `agda --js` + node против РЕАЛЬНЫХ фикстур (`npm test`, fixtures/reads.json).
- DOM/e2e → `npm run test:smoke`: happy-dom + живой сервер (нужны pg-scratch + cxm-server-pg
  на :8138 с `CXM_DEV=1 PSYCH_ADMIN_LOGIN=admin@dev PSYCH_ADMIN_PASSWORD=adminpass123`).
- Глазами → `npm run dev` → http://127.0.0.1:8137/dev/ (каталог виджетов; same-origin
  прокси на :8138, CORS не нужен).

План/решения/находки: `../docs/cxm-ui-plan.md`.
