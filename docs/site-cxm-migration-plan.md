# sergey-site → CXM — план переделки

> **Статус:** план. Исполняется по фазам; отмечать `- [x]` по мере готовности.
> **Что это:** перевод сайта «В точку» (`~/sergey-site`) с бэкенда `crm-server`
> (`agdelte-crm` + `agdelte-pack-psych`) на новое ядро **`agdelte-cxm`** (готово, фазы 0–12).
> **Ядро-источник истины:** `~/cxm-core/docs/cxm-plan.md`, `~/cxm-core/docs/cxm-description.md`, код `~/.agda/agdelte-cxm/`.
> **Референсы (читать, мапить):** `~/.agda/agdelte-pack-psych/Psych/*.agda` (контракт booking),
> `~/.agda/agdelte/server/CrmServer.agda` (серверный entry + core-роуты консоли),
> `~/sergey-site/agdelte-web/{Psych/Web,Console/Web}.agda` (фронт-клиенты),
> `~/sergey-site/_deploy/crm-server@.service` (деплой).

---

## 0. Контекст и рамки

**Архитектура `~/sergey-site` (выверено инвентаризацией + nginx, 2026-07-02):**
- **`crm-server`** — ЕДИНСТВЕННЫЙ живой бэкенд сайта. Деплоится из `agdelte/server/CrmServer.agda`
  (= `agdelte-crm` core + `agdelte-pack-psych` через `routeExt`), WAL `/var/lib/crm/%i/crm.wal`,
  сокет `/run/sites/%i/crm-server.sock`. **Это и мигрируем на CXM.**
- `booking-service/` (Haskell, Google Calendar) — **фактически МЁРТВ** (nginx-site.conf: «booking
  теперь ВНУТРИ CRM, отдельного booking-service нет»). ВНЕ РАМОК; в Фазе 8 — убрать мёртвый юнит.
- **ДВА фронтенда бьют в `crm-server`:**
  - **Лендинг** `site/www/index.html` (обычный HTML/JS) — публичный виджет брони → `/psych/availability`,
    `/psych/book` (на главном домене, rate-limited, только эти два роута).
  - **Операторская консоль** `crm-www` (agda `agdelte-web/Console/Web.agda` + `Psych/Web.agda` →
    `site/crm-www/_build/*.mjs`) на `crm.<домен>` за JWT — полный CRM/psych API.
- `telegram-bot/` — **ВНЕ РАМОК**.

**Явно вне рамок (решение пользователя, 2026-07-02):** Google Calendar, telegram-bot,
`booking-service`.

**Инвариант успеха:** новый `cxm-server` отдаёт **тот же HTTP-контракт** (пути + JSON), что и
`crm-server`; фронт (`Psych.Web`/`Console.Web`) правится минимально; существующие данные
`crm.wal` мигрируются в `cxm.wal`.

---

## Зафиксированные решения (не переигрывать)

1. **Сохранять API-контракт.** Новый сервер отдаёт те же пути (`/psych/*`, `/payments/*`, core
   консоли) и те же JSON-поля. Это сводит переделку фронта к near-zero и делает переезд серверным.
   Если поле неизбежно меняется — правим и фронт в Фазе 7, но по умолчанию контракт стабилен.
2. **Сессия = `Cxm.Appointment`** (готовый core-примитив): время+статус+ресурс. CRM `Activity`
   переформулирован сюда (§9.1 cxm-plan). Пакет = `Episode` + `Entitlement`; кредиты —
   `sessionsUsedForEpisode`.
3. **Psych — тонкий pack поверх ядра.** Вся механика в `agdelte-cxm`; вертикаль = конфиг
   (каталог/часы) + `tryRoute` через `Cxm.Api.routeExt`/`gatePack`. Ядро вертикаль не называет.
4. **Снос `agdelte-crm`/`pack-psych`/`Crm*` из `agdelte/server`** — ПОСЛЕ зелёного паритета
   (blast radius: `agdelte/server` 7 файлов + `pack-psych` + `agdelte-cxm/FromCrm`).
5. Google Calendar / telegram-bot / booking-service — не трогаем (booking-service уже мёртв).
6. **JWT-вход обязателен** (аудит: nginx `auth_request /_authcheck`→`/auth/me` гейтит консоль) —
   `/auth/login` + `/auth/me` в CXM обязательны, не опция.
7. **Сохранить имя сокета `crm-server.sock`** (или синхронно править ОБА nginx-шаблона +
   rate-limit зоны + `/_authcheck`). Дефолт: тот же сокет → nginx правится минимально.

---

## Контракт `crm-server` (цель паритета)

**Psych-роуты** (`Psych/Api.agda tryRoute`, через `routeExt`):
- `GET  /psych/offerings` → `{data:[{code,label,sessions,price}]}`
- `POST /psych/availability {type,from,days}` → `{data:[{start,end}]}`
- `POST /psych/book {type,start,name,email,phone,comment}` → `{data:{id}}` | `{error}`
- `POST /psych/purchase {offering,name,email}` → `{data:{id:<engId>}}`
- `POST /psych/session {eng,start}` → `{data:{id}}` (списать кредит пакета)
- `POST /psych/package {eng}` → `{data:{eng,offering,label,sessionsTotal,sessionsUsed,sessionsLeft,price}}`
- `POST /psych/cancel {act}` → `{data:{result:"canceled"|"late_canceled"}}`
- `POST /psych/complete {act}` · `POST /psych/no-show {act}` · `POST /psych/reopen {act}` → `{data:{ok}}`
- `POST /psych/reminders/run {leadHours}` → `{data:{reminded:N}}`
- `POST /payments/create` · `/payments/record` · `/payments/webhook` (YooKassa; `Psych/Payments.agda`)

**Core-роуты консоли** (из `nginx-crm.conf` regex — точный список): `auth/login` · `auth/me`
(nginx `auth_request /_authcheck`→`/auth/me` гейтит ВСЮ консоль ⇒ **JWT обязателен**) ·
`activities` · `parties` · `participations` · `engagements` · `accounts` · `outbox` · `events` ·
`assignments` · `payments` · `psych/*`. Плюс `/payments/webhook` (ЮKassa callback, без auth).

---

## Пробелы ядра CXM, которые надо закрыть

> NB: в контракт-таблице ниже «✅» = «команда/запрос ядра ГОТОВЫ», НЕ «миграция данных
> согласована». Согласование миграции с моделью `Appointment` — отдельный пункт (аудит-2 #1).


- ✅ **СДЕЛАНО:** `Cxm.Commands.enqueueNotification` + `markSent` (Outbox-интент).
- ✅ **СДЕЛАНО:** `Cxm.Commands.reopenAppointment` (Completed/NoShow → Scheduled; note: не
  перепроверяет слот-конфликт — аудит-3 #3, паритет с CRM).
- ✅ **СДЕЛАНО:** `Appointment.apRemindedAt : Maybe ℕ` (ripple Wire/Base/codec/тесты).
- ✅ **СДЕЛАНО:** `Cxm.Commands.dueAppointmentReminders` (окно `[now, now+lead]`, аудит-3 #1 —
  исключены прошедшие) + `markApptReminded`.
- ✅ **СДЕЛАНО:** `FromCrm` переписан на `Activity→SetAppointment` (аудит-2 #1), soft-deleted не
  мигрируются (аудит-3 #2); `MigrateTest` обновлён.
- ✅ **СДЕЛАНО:** `Cxm.Api` `POST /auth/login` + `GET /auth/me` (JWT через `agdelte-auth`) — консоль.
- ✅ **СДЕЛАНО:** Psych-каталог (`Offering`/цены/`Settings`-часы) в pack `PsychCxm.Catalog` (baked-config).
- 🐞 **ФИКС (live-тест):** `Cxm.Api` `fieldOr`/`natOr` звали `jsonGetField (reqBody req) name` — аргументы
  перепутаны (сигнатура `jsonGetField fieldName json`), из-за чего ВЕСЬ POST-API читал только дефолты
  (логин не находился, поля пустые). Исправлено в `Cxm.Api` и `PsychCxm.Api`; проверено вживую.
- ✅ **ДОБАВЛЕНО в фреймворк:** `Agdelte.FFI.Server.listenUnix` + `Http.serveUnix` (HTTP-over-unix-socket,
  Warp `runSettingsSocket`, AF_UNIX, chmod 0660) — сервер сам создаёт сокет для nginx (реш. #7).

YooKassa-клиент (`Agdelte.Payment.YooKassa.createPayment`/`verifyWebhookSig`) — **готов**, переиспользуем.

---

## Фаза 0 — Разведка контракта (без кода)

- [ ] Прочитать **`site/www/index.html`** (лендинг-виджет, обычный JS) — точные пути/JSON для
      `/psych/availability` и `/psych/book` (аудит #1: этот фронт пропускать нельзя).
- [ ] Прочитать `agdelte-web/Psych/Web.agda` + `Console/Web.agda`: точные пути/JSON, заголовки
      (Authorization Bearer), формат ошибок, как хранится/шлётся JWT.
- [ ] `CrmServer.agda` — сверить обработчики против nginx-списка роутов (уже известен, см. контракт).
- [ ] Зафиксировать «контракт-таблицу» (эндпойнт → CXM-команда/запрос → отличия JSON) приложением.
- **DoD:** полный список эндпойнтов ОБОИХ фронтов + расхождений; решение «сохранить/поменять».

## Фаза 1 — Добивки ядра CXM (+ тесты)

Читать: `Cxm/Commands.agda`, `Cxm/Bus.agda`, `agdelte-auth/Agdelte/Auth/JWT.agda`.

- [x] `Cxm.Commands.enqueueNotification` (Outbox `OutPending`) + `markSent`. `refl`-тест (emit→op). ✅
- [x] `Cxm.Commands.reopenAppointment` (гард `Completed`/`NoShow` → `ApScheduled`). ✅
- [x] **Напоминания по сессиям (аудит-2 #2/#3):** `Appointment.apRemindedAt` +
      `dueAppointmentReminders` (окно `[now, now+lead]`) + `markApptReminded`. ✅
- [x] `Cxm.Api`: `POST /auth/login` → JWT (`signJWT`/`verifyPassword`), `GET /auth/me` (`verifyJWT`),
      `POST /auth/users` (создать оператора, `hashPassword`); principal-aware `authz`; `runRouter`
      берёт токен+секрет из `InstanceConfig` (`cfgApiToken`/`cfgJwtSecret`). ✅
- **DoD:** модули typecheck; `refl`-тесты на новые команды; `Cxm.All`/`Test.All` зелёные, нейтральность чиста.

## Фаза 2 — Тонкий psych-pack на CXM

Читать: `Psych/{Api,Catalog,Schedule,Booking}.agda` (маппинг), `Cxm/{Commands,Schedule,Query}.agda`.

- [x] Новая библиотека `agdelte-pack-psych-cxm` (`depend: … agdelte-cxm`), namespace `PsychCxm.*`.
- [x] `Catalog`: `Offering`-каталог «В точку» (intro/single/path5/path10) + `Settings` (часы 10–19
      МСК, notice/cancel/horizon) как данные + offering↔`epJtbd` кодек + `packageProtocol`.
- [x] `tryRoute` зеркалит 13 psych-роутов на готовые CXM-команды:
      availability→`Schedule.availabilityFrom`+`resourceBusy`; book→`createSubject`+`bindIdentity`+
      `bookAppointment`(+`validateSlot`); purchase→`createSubject`+`createEpisode`+`grantEntitlement`;
      session→`bookIntoEpisode` (creditLimit = `offering.oSessions`, аудит-2 #4); package→
      `sessionsUsedForEpisode`; cancel/complete/no-show/reopen→ appointment-переходы;
      reminders/run→**`dueAppointmentReminders`** (не Promise-версия, аудит-2 #2)+`enqueueNotification`
      +`markApptReminded` (email клиента — из `Identity` субъекта appointment'а).
- **DoD:** typecheck ✅; pack зелёный; весь флоу (offerings→availability→book→purchase→session→
  package→cancel/complete→reminders) проверен вживую через unix-сокет.

## Фаза 3 — Платежи (YooKassa) на CXM

Читать: `Psych/Payments.agda`, `Agdelte.Payment.YooKassa`.

- [x] Портирован `/payments/{create,record,webhook}` в `PsychCxm.Payments` на `Cxm.Payment` +
      `recordPayment`/`markPaymentSucceeded` (грант `Entitlement` при успехе) + open package Episode.
      Контракт сохранён.
- [x] Вебхук: `verifyWebhookSig` (HMAC); idempotent (guard `PayPending`→`Conflict`).
- **DoD:** typecheck ✅; контракт `/payments/*` сохранён; успех → `Entitlement` + `Episode`.

## Фаза 4 — Операторские роуты консоли на CXM

Читать: Фаза-0 контракт-таблица, `Crm.Api` (роуты консоли).

- [x] **Операторская HTTP-поверхность добита в `Cxm.Api`** (CXM-нативные пути, покрывают весь
      `Crm.Api`): GET `/subjects|/episodes|/appointments|/edges|/accounts|/outbox|/events|/assignments`;
      POST `/subjects(+/delete)|/episodes(+/transition)|/edges(+/by-subject)|/appointments(+/cancel|
      /complete|/no-show|/by-episode)|/accounts|/charge|/credit|/notifications|/outbox/drain|
      /events/dispatch|/assignments(+/revoke)|/auth/{login,me,users}`. JSON-энкодеры + enum→string;
      за `authz`(principal)+`canAssign`. Всё зелёное. `drainOutbox` добавлен в Commands.
      **Осталось (тонкое):** если старый фронт `site/www` не переписываем — алиасы контрактных путей
      (`/parties`→subjects и т.п.); но сайт «с нуля» ⇒ фронт целится в нативные пути. `/psych/*` и
      `/payments/*` — pack (Фазы 2/3).
- **DoD:** typecheck ✅; операторские эндпойнты отвечают `{data}`/`{error}`.

## Фаза 5 — `CxmServer` entry

Читать: `CrmServer.agda`.

- [x] `agdelte/server/CxmServer.agda`: `runInstance` (open+seed из `InstanceConfig`) + `seedAdmin`
      (bcrypt, idempotent) + `routeExt (gatePack cfg "psych" (tryRoute pcfg h)) (allow-all authz) token`.
      Env-конфиг → `InstanceConfig` + `PayConfig`. Слушает unix-сокет (`CXM_SOCKET`) / TCP fallback.
- [x] Сборка: `agdelte.cabal` exe `cxm-server` + npm `gen/build:cxm-server` (`-i …/agdelte-cxm …`).
- **DoD:** ✅ `cxm-server` собирается, линкуется, стартует; curl по unix-сокету: логин, покупка,
      сессия (списание кредита), бронь, listing — всё отвечает `{data}`/`{error}`.

## Фаза 6 — Деплой + миграция данных

Читать: `_deploy/crm-server@.service`, `Cxm/Migrate/FromCrm.agda`.

- [x] ~~Миграция данных CRM→CXM~~ **ОТМЕНЕНА** (решение 2026-07-02: сайт стартует «с нуля», данные
      не сохраняем). `FromCrm`/`MigrateTest` УДАЛЕНЫ, временный `agdelte-crm`-depend из `agdelte-cxm`
      снят → **ядро CXM полностью независимо от crm**. IO-обёртка миграции не нужна.
- [x] `_deploy/cxm-server@.service` (по образцу `crm-server@`): `StateDirectory=cxm/%i`, `CXM_SOCKET`
      = `/run/sites/%i/cxm-server.sock`, `Group=www-data` (сервер сам chmod'ит сокет 0660 — umask не
      нужен), env (WAL/токен/YooKassa/JWT-secret/ADMIN).
- [x] **nginx:** `_deploy/nginx-cxm.conf.tmpl` (консоль: auth_request→`/auth/me`, публичные
      login/availability/book/webhook, CXM-нативный regex операторских путей, **статика за
      auth_request** — запрос пользователя) + `_deploy/nginx-site-cxm.conf.tmpl` (лендинг). Сокет
      `cxm-server.sock` (реш. #7 — но имя crm→cxm; сайт «с нуля»).
- [ ] **ОСТАЁТСЯ:** обновить `_deploy/add-site.sh`/`install.sh` — подставлять cxm-шаблоны + собирать
      `cxm-server` вместо `crm-server` (оркестрация деплоя; при применении на сервере).
- **DoD:** старт из пустого `cxm.wal` ✅ (проверено локально); прод-применение — при раскатке.

## Фаза 7 — Фронт: сверка и правки

Читать: Фаза-0 расхождения.

- [x] Лендинг `site/www/index.html` — БЕЗ правок: его `window.BookingApi` уже бьёт
      `/psych/availability`+`/psych/book` и разворачивает `{data}/{error}` (контракт CXM = CRM).
- [x] `Console.Web`/`Console.Wire` РЕПОЙНТНУТЫ на CXM-нативы (/appointments,/subjects,/episodes;
      appointment.subject = клиент напрямую, participation-join схлопнут; offering из episode.jtbd;
      email из /subjects join). SDK `PsychCxm.Client` (зеркало `Psych.Client`). `build.sh` → cxm-либы.
      Компилируется в JS ✅. Обогащены нейтральные CXM-энкодеры (subjects+email, appointments+episode,
      episodes+jtbd, +GET /identities) — проверено вживую, сервер отдаёт ровно то, что декодит консоль.
- [x] `Psych.Web` (старый standalone-виджет booking.html) — снят со сборки (лендинг self-contained).
- [ ] **ОСТАЁТСЯ (деплой):** скопировать `agdelte-web/_build/*.mjs` → `site/crm-www/_build/` при раскатке.
- **DoD:** лендинг-бронь работает (контракт); консоль собирается и декодит живой ответ cxm-server ✅.
  Полный браузерный прогон логина/сценария — при раскатке (headless-верификация контракта пройдена).

## Фаза 8 — Снос старого (после зелёного паритета, по подтверждению)

- [x] Сняты с регистрации (`~/.agda/libraries`) и УДАЛЕНЫ каталоги `agdelte-crm`, старый
      `agdelte-pack-psych`. `FromCrm`/depend уже были сняты ранее.
- [x] Из `agdelte/server` удалены 8 crm/psych-файлов (CrmServer + Crm*/Authz/Psych-schedule/
      schema-spike/walrec тесты); из `agdelte.cabal` — 8 exe-станц; из `package.json` — ~20
      crm/psych-скриптов (валидный JSON); `scripts/{api-test,crm-live-run}.sh` удалены;
      `check-neutrality.sh` Guard 2 репойнтнут на `agdelte-cxm/Cxm`. `RbacTest`/`yookassa`/store
      тесты сохранены (от crm не зависят).
- [x] `_deploy`: удалены `crm-server@.service`, мёртвый `booking-service@.service`, старые
      `nginx-{crm,site}.conf.tmpl`. `add-site.sh`/`site.env.example`/`check-site.sh` репойнтнуты на
      `cxm-server` + cxm-шаблоны. (`site/bin/crm-server` бинарь → пересобрать как `cxm-server` при раскатке.)
- **DoD:** ✅ ни код, ни конфиг не ссылаются на `agdelte-crm` (только пояснит. комментарии); обе
      стражи нейтральности зелёные; `Cxm.AllIO`/`PsychCxm.*` типизируются; `cxm-server` собирается.
      ⚠️ Потеря: generic-infra тесты (WalRecovery/SchemaSpike) были crm-coupled — удалены; при
      желании переписать на `Cxm.*` (отдельная задача).

---

## Порядок зависимостей

```
0 разведка контракта
1 добивки ядра (enqueueNotification/reopen/auth) ← нужны 2–4
2 psych-pack на CXM        ← нужен 1
3 платежи                  ← нужен 1
4 консоль-роуты + JWT      ← нужен 1
5 CxmServer entry          ← нужны 2,3,4
6 деплой + миграция данных ← нужен 5
7 фронт                    ← нужны 5,6
8 снос старого (GATE)      ← нужны 1–7 зелёные + подтверждение
```

## Риски

- **Объём консоли (Фаза 4)** — главный множитель; список роутов известен (nginx), но у каждого
  свой JSON/маппинг CRM-имён на CXM-сущности — выверить в Фазе 0.
- **Точные JSON-поля ДВУХ фронтов (Фаза 7)** — лендинг `site/www/index.html` + agda-консоль;
  если контракт где-то разошёлся, правок больше.
- **Миграция ≠ модель (аудит-2 #1, HIGH)** — `FromCrm` (Activity→Event) рассогласован с booking
  (читает Appointment); без переписи мигрированные сессии не видны в availability/кредитах →
  двойные брони. Обязательно переписать `FromCrm` (Фаза 6) + `Appointment.apRemindedAt` (Фаза 1).
- **JWT** — подтверждён обязательным (nginx `auth_request`); Фаза 1-auth и часть Фазы 4 — в силе.
- **Имя сокета / nginx** — держим `crm-server.sock`, иначе правка обоих vhost + зон rate-limit.
- Google Calendar / telegram-bot / booking-service — вне рамок; booking-service уже мёртв.
