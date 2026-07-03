# CXM → облачная платформа — план доработки

> **Статус:** план. Исполняется по фазам; отмечать `- [x]`.
> **Что это:** довести CXM до облачной платформы вида «флот изолированных CXM-инстансов»
> (один инстанс на психолога, своя WAL/база) + **универсальный инструментарий интеграции с
> ЛЮБЫМ сайтом** (site-agnostic: стабильный публичный API + drop-in JS-SDK + встраиваемые
> themeable-виджеты + исходящие вебхуки) + control plane для провижининга/управления инстансами.
> sergey-site НЕ цель, а первый потребитель тулкита (dogfood).
> **Опора (аудит 2026-07-02):** ядро НЕ переделывается — DB-per-instance уже by construction
> (`runInstance cfg` → свой WAL по `shWalPath`; `cxm-server@%i` + `add-site.sh` = инстанс на slug).
> Не хватает: (A) 3 интеграционных шва, (B) control plane, (C) [опц.] SaaS-обвязка.

---

## Зафиксированные решения (не переигрывать)

1. **Модель изоляции = instance-per-tenant (DB-per-instance).** Один психолог = один
   `cxm-server`-инстанс = свой WAL/сокет. НЕ мульти-tenant-в-одной-базе (рантайм-изоляция в
   ядре НЕ enforced — чтения не фильтруют по tenant; + регулируемые терапевт-данные, §9.9).
2. **Integration-токены — store-backed, минтятся в рантайме** оператором (не env-конфиг):
   платформе нужна самообслуживаемая выдача токена под свой сайт. Новая сущность в сторе +
   команды create/revoke + `verifyTok` = скан.
3. **`CxmServer` обслуживает ОБА контура:** `routeExt` (операторский API + паки, за JWT/nginx) и
   `routeSite` (публичный `/v1` для сайта, за integration-токеном) — диспетч по префиксу пути
   (`/v1/*` → routeSite, иначе routeExt). Наружу операторский API не течёт.
3a. **Тулкит интеграции — site-agnostic и переиспользуемый ЛЮБЫМ сайтом.** Три поставки:
   (i) стабильный версионированный публичный API `/v1` (контракт-контракт, CORS, scoped-токен);
   (ii) **drop-in JS-SDK** (фреймворк-независимый, без сборки у клиента) поверх `/v1`;
   (iii) **встраиваемые themeable-виджеты** (web components, `<script>`-embed; agda→js уже умеет,
   лендинг-виджет = частный случай). Никакой привязки к конкретному сайту/вертикали в тулките.
4. **Доставка вебхуков — Outbox-driven воркер + генерик исходящий HTTP POST (FFI)** + ретраи;
   подпись (`webhookSignature`) уже есть. Outbox уже хранит интенты — вебхук = такой же интент.
5. **Control plane = провижнер над механикой `add-site.sh` + реестр инстансов.** Провижининг
   остаётся host-privileged (systemd/nginx/certbot). Реестр — источник истины по инстансам
   (slug/домен/статус/паки). Кросс-инстансная идентичность/SSO — OFF (каждый инстанс = свой
   trust/data boundary).
6. **SaaS-обвязка (самрегистрация/биллинг) — отдельная поздняя фаза / вне первого прохода.**

---

## Фаза 1 — Интеграционные швы в ядре + entry (Agda, проверяемо)

Читать: `Cxm/Site.agda`, `Cxm/Api.agda` (routeSite/v1Authorized), `Cxm/Store/*`, `server/CxmServer.agda`.

- [x] **IntTokenRow как сущность стора:** `Cxm.Site` (row + `verifyTokenIn`) + ripple
      `Wire`(схема/кодек)/`Store.Base`(map+`SetIntToken`/`DelIntToken`+apply+emptyBase)/`Store.Codec`
      (теги V/v)/`Store.Interface`(`integrationTokensT`). Индекс не нужен (скан; токен не ℕ).
      Поля: id/tenant/token/scope/origin/createdAt/revokedAt(Maybe 0-sentinel).
- [x] **Команды:** `createIntegrationToken (token scope origin)(tenant now)`,
      `revokeIntegrationToken (id now)` (soft, аудит-строка живёт). `verifyTokenIn` (не revoked).
- [x] **Операторские роуты** (за JWT): `GET /integration-tokens`, `POST /integration-tokens
      {scope,origin}` (секрет генерится `randomBytesB64`, отдаётся 1 раз `{id,token}`),
      `POST /integration-tokens/revoke {id}`.
- [x] **`verifyTok` для `/v1`:** `verifyTokenIn t (map proj₂ (tscan integrationTokensT b))` на
      снапшоте базы (per-request).
- [x] **Компоновка в `CxmServer`:** диспетч `OPTIONS`/`/v1/*` → `routeSite verifyTok h`, иначе
      `routeExt (gatePack …) authz token secret h`. CORS/preflight в routeSite.
- [x] **Омниканальность (уточнение пользователя):** добавлен канал `Channel.Integration` — ingest
      с `/v1` тегируется им по умолчанию; интеграция = ещё один канал, унификация по субъекту через
      identity-bridge (provisional+merge). Ripple Event/Wire (chCodes/chCode/chOfOrd) — тесты зелёные.
- **DoD:** ✅ typecheck (AllIO/Test.All/pack); `cxm-server` собран+слинкован; live через unix-сокет:
      минт токена → `POST /v1/events` с токеном = committed; без/с чужим = 401; провижн субъекта+
      ExperienceEvent. Контур `/v1` нейтрален — для ЛЮБОГО сайта.
      NB: `GET /events` = доменная шина (bus), НЕ лог ExperienceEvent (§8.2). Операторский GET по
      ExperienceEvent-логу можно добавить позже (не требуется для Фазы 1).

## Фаза 2 — Исходящая доставка вебхуков — ✅ ВЫПОЛНЕНА блоком D `cxm-concept-upgrade-plan.md` (2026-07-02): Agdelte.FFI.HttpClient + forkLoopEvery, Outbox-ретраи (attempts/OutFailed/backoff), Cxm.Worker (deliver-адаптер, headless), wiring в CxmServer (CXM_WORKER_SEC/WEBHOOK_SECRET/MAX_ATTEMPTS/REMIND_LEAD_H), подпись X-Cxm-Timestamp+Signature (anti-replay). Live: доставка 200→sent; 404→ретраи/бэкофф; периодика reminders+bus.

Читать: `Cxm/Bus.agda` (Outbox), `Cxm.Api.webhookSignature`, `Agdelte.Payment.YooKassa` (http-client FFI образец).

- [ ] Генерик исходящий `httpPostSigned : (url secret topic body : String) → IO (status)` в
      `Agdelte.FFI` (или переиспользовать http-client из agdelte-payments): POST с заголовком
      подписи `webhookSignature`.
- [ ] Outbox расширить каналом `webhook` (target = URL); `deliverOutbox` воркер (IO-loop):
      читать pending → POST → `markSent`/ретрай с backoff. Идемпотентность (уже не-двойной drain).
- [ ] Заголовок подписи с timestamp+nonce (закрыть audit #D anti-replay).
- **DoD:** typecheck; воркер доставляет тестовый вебхук на локальный приёмник; ретрай при 5xx.

## Фаза 3 — Тулкит интеграции для ЛЮБОГО сайта (SDK + виджеты)

Читать: `Cxm.Api` routeSite/v1 контракт, `agdelte` (agda→js, web-components), лендинг-виджет как образец.

- [ ] **Публичный контракт `/v1` зафиксировать** как стабильный версионированный API (события,
      identity-bridge, доступность/бронь для booking-паков) + написать контракт-док (пути/JSON/токен/CORS).
- [ ] **Drop-in JS-SDK** `cxm-sdk.js` (фреймворк-независимый, без сборки у клиента): `Cxm.init({baseUrl,
      token})` → `track(event)`, `identify(channel,id)`, `book(...)` и т.п. поверх `/v1`. Один
      `<script>` — работает на любом сайте (Tilda/WP/custom). Никакой вертикали в SDK.
- [ ] **Встраиваемый themeable-виджет** (web component `<cxm-booking>` / `<script data-cxm>`):
      обобщить лендинг-виджет (`window.BookingApi`) в самодостаточный embed, настраиваемый атрибутами
      (baseUrl, offering, тема-CSS-переменные). agda→js остров + тонкий loader.
- [ ] **sergey-site как dogfood:** переключить его лендинг с inline-`BookingApi` на этот SDK/виджет —
      доказательство site-agnostic (тот же тулкит на «любом» сайте).
- **DoD:** пустой статический HTML + один `<script src=cxm-sdk.js>` + `<cxm-booking token=…>` →
      рабочая бронь на живом `cxm-server`, без сборки на стороне сайта; тема настраивается атрибутами.

## Фаза 4 — Control plane: провижнер + реестр

Читать: `_deploy/add-site.sh`, `cxm-server@.service`, `nginx-cxm*.tmpl`.

- [ ] **Реестр инстансов** (источник истины): slug, домен, CRM-домен, активные паки, статус,
      created. Формат: JSON-файл флота (или маленький отдельный CXM-инстанс «control» — обсудить).
- [ ] **Провижнер `cxm-provision <slug>`** (обёртка/расширение add-site.sh): выделить slug →
      записать `InstanceConfig`/env → создать WAL-каталог (StateDirectory) → `systemctl enable
      --now cxm-server@slug` → отрендерить nginx-vhost(ы) → выпустить cert → засидить админа →
      записать в реестр.
- [ ] **Лайфцикл:** `cxm-suspend`/`cxm-resume`/`cxm-remove <slug>` (stop/disable/prune + nginx +
      сохранение/архив WAL). Идемпотентность (add-site уже прунит устаревшие юниты).
- [ ] **Обзор флота:** `cxm-fleet` (список инстансов + статус из реестра + `systemctl is-active`).
- **DoD:** из чистого хоста одной командой поднимается новый психолог-инстанс (свой WAL/домен/
      админ); suspend/remove работают; реестр отражает реальность.

## Фаза 5 — [опц./поздняя] Онбординг + биллинг (SaaS)

- [ ] Самрегистрация (публичная форма → заявка → провижининг по approve).
- [ ] Тарифы/лимиты/оплата (переиспользовать YooKassa-клиент). Вне первого прохода.

---

## Порядок и риски

```
1 интеграционные швы (токены+routeSite)  ← ядро, публичный /v1 контур
2 доставка вебхуков                       ← генерик HTTP POST FFI (edge)
3 тулкит интеграции (SDK + виджеты)        ← site-agnostic, для ЛЮБОГО сайта; dogfood sergey-site
4 control plane (провижнер+реестр)         ← ops/host-privileged, продуктизация add-site.sh
5 SaaS (онбординг/биллинг)                 ← позже
```

- **Риск (Фаза 3):** провижининг требует root (systemd/nginx/certbot) — провижнер = привилег.
  host-агент; нужно решить, где он живёт (cron/CLI/daemon) и как триггерится (ручной approve vs API).
- **Риск (Фаза 2):** генерик исходящий HTTP + ретраи — новый FFI; держать доставку на edge, ядро
  хранит только интент (принцип: ядро наивно к сети).
- **tenant-изоляция в одной базе** остаётся НЕ enforced — сознательно (модель = instance-per-tenant).
  Если позже понадобится — отдельная работа (tenant-scope в чтениях + principal→tenant).
- Google Calendar / telegram-bot — вне рамок (прежнее решение).
```
