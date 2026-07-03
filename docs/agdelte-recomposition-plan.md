# Структурная рекомпозиция репозиториев (Agdelte / store / payments / CXM)

> **Статус:** план (2026-07-03). Self-contained, фазированный. Отмечать `- [x]`.
> **Принцип разбиения:** по **зависимости и природе**, НЕ по префиксу `agdelte-*`. Репо = стек ×
> аудитория, не фича. Каждая фаза закрывается проверкой (typecheck + стражи + сборка затронутых
> целей). Ничего не удаляем хард — переносы через `mv`/копию с проверкой перед удалением оригинала.

## Зафиксированные решения (не переигрывать)

Р1. **Ось разбиения — зависит ли оно от фреймворка `agdelte`:**
    - зависит (`agdelte-auth`, FFI.Crypto/Server) → живёт С фреймворком (Agdelte-репо);
    - stdlib-only, независимо (`agdelte-store`, `agdelte-payments`) → самостоятельная инфра, НЕ «Agdelte».
Р2. **CXM-либы — генерик-инфру НЕ присваивают.** `store/auth/payments` НЕ переезжают в `cxm-core`;
    CXM тянет их как зависимости по имени. `cxm-core` = движок CXM (уже вынесен, 2026-07-03).
Р3. **Postgres-ДРАЙВЕР — в `agdelte-store`** (не в UI-фреймворке); заложено в дизайн: `Storage.Schema`
    → и WAL-кодек, и SQL-DDL; Postgres = «другой интерпретатор той же схемы». **Уточнение аудита:** в
    store едет чистый драйвер (`FFI.Postgres`, только builtins) + будущий Schema→DDL-интерпретатор
    (тоже чистый). РАННЕР миграций (`Server.Migrate`) и спайки нужны файловой системе/IO/Warp
    (`FFI.{Shared,FileSystem,Server}`) → это APP-glue, остаётся во фреймворке (в store = цикл).
Р4. **Postgres сейчас — СПАЙК, не бэкенд** (pg-spike доказывает лишь выживание пула hpgsql через Warp;
    Schema→DDL интерпретатор отложен). Переезд собирает правильный дом, прод-бэкенда не создаёт.
Р5. `agdelte-courses` — в `~/.agda/_archive/` (сделано 2026-07-03; легаси, не в активное дерево).
Р6. **Смэлл на потом (НЕ в этом плане):** CXM — headless-бэкенд, но тянет весь UI-фреймворк ради
    серверных FFI. Отделение FFI/server-части от реактивного-UI — отдельный крупный рефактор.

## Целевая раскладка

**ФАКТИЧЕСКАЯ раскладка (3 репо, DONE 2026-07-03):**
```
~/.agda/agdelte/       = ФРЕЙМВОРК (reactive UI + FFI + build harness: agdelte.cabal, hs/,
                          server/ mains, gen-скрипты cxm-server/pg-spike/migrate-demo). Свой репо.
~/agdelte-addons/      = agdelte-store (+ Postgres-ДРАЙВЕР Storage.Postgres + hs/) +
                          agdelte-auth + agdelte-payments. [раннер Migrate + pg-спайки — во
                          фреймворке: тянут FFI.{FileSystem,Server}/Warp, в store = цикл]
~/cxm-core/            = cxm + cxm-pack-psych (переименованы, Фаза D) + server/CxmServer + docs
<site>-репо (будущее)  = продукты — потребляют всё вышеперечисленное
~/.agda/_archive/      = agdelte-courses + до-переносные git-оригиналы store/auth/payments
```
> Отличие от первой редакции: фреймворк НЕ переезжал (у него уже свой репо `~/.agda/agdelte`),
> а `auth` уехал в `agdelte-addons` (не с фреймворком) — решение пользователя; auth привязан к
> фреймворку `depend:`-ом, но это не мешает жить в отдельном репо (резолв по имени).

## Фаза A — Postgres → `agdelte-store` — ✅ DONE (2026-07-03)

> **ИСПРАВЛЕНО АУДИТОМ 2026-07-03.** Первая редакция предлагала перенести в store `Server.Migrate`
> + спайки — это **ЦИКЛ**: `Server.Migrate`/спайки импортят фреймворковые `FFI.{Shared,FileSystem,
> Server}`, а `agdelte` УЖЕ зависит от store (`depend: agdelte-store`). Store→agdelte + agdelte→store
> = запрещённый цикл. **В store едет ТОЛЬКО чистый драйвер** (`FFI.Postgres` импортит лишь
> `Agda.Builtin.*`); раннер+спайки остаются во фреймворке, им правим лишь импорт pg.

Делается «на месте» в `~/.agda`, независимо от разнесения по репо. Читать: `agdelte/src/Agdelte/FFI/
Postgres.agda`, `agdelte/hs/Agdelte/Postgres.hs`, `agdelte/src/Agdelte/Server/Migrate.agda`,
`agdelte/server/{PgSpike,MigrateDemo}.agda`, `agdelte/agdelte.cabal` (pg-spike/migrate-demo),
`agdelte-store/agdelte-store.agda-lib`.

- [x] **ТОЛЬКО чистый драйвер → store, переименование в `Agdelte.Storage.Postgres`:**
      `FFI.Postgres.agda` (импортит лишь `Agda.Builtin.*` — ноль фреймворка/stdlib) →
      `agdelte-store/Agdelte/Storage/Postgres.agda`. Store остаётся stdlib-only, цикла нет.
- [x] **Haskell-драйвер** `agdelte/hs/Agdelte/Postgres.hs` → `agdelte-store/hs/Agdelte/Postgres.hs`
      (Haskell-имя модуля `Agdelte.Postgres` оставить — на него ссылается FOREIGN; только переезд).
      Store обзаводится каталогом `hs/`.
- [x] **ОСТАЮТСЯ во фреймворке** (нужны `FFI.{Shared,FileSystem,Server}`/Warp → в store нельзя):
      `Server.Migrate` (раннер), `server/PgSpike.agda`, `server/MigrateDemo.agda`,
      `docs/POSTGRES-SPIKE.md`. Им правим ТОЛЬКО импорт `Agdelte.FFI.Postgres` →
      `Agdelte.Storage.Postgres` (резолвится: `agdelte → store` уже объявлен).
- [x] **Харнесс — вынужденно (b), НЕ выбор:** `pg-spike` нужен Warp ⇒ его cabal-таргет ОСТАЁТСЯ в
      сборке `agdelte`; правим только `hs-source-dirs`/`-i` на store (`store/hs/` + `Storage.Postgres`).
      «Свой cabal у store» покрыл бы лишь гипотетический ЧИСТЫЙ store↔pg-тест (без Warp) — писать
      отдельно, если понадобится; существующие спайки на нём собрать нельзя.
- [x] (опц.) Чтобы `src/` фреймворка не начал импортить store, `Server.Migrate` можно вынести из
      `agdelte/src/` в app/deploy-слой (ему всё равно нужны фреймворк-FFI, в store он не идёт). Не
      обязательно; текущий `depend: agdelte-store` это уже покрывает.
- **DoD:** `agdelte-store` typecheck (Agda) зелёный; `pg-spike` + `migrate-demo` собираются
      (харнесс в `agdelte`, драйвер из store); **WAL-путь CXM не затронут** (`cd ~/cxm-core/agdelte-cxm
      && agda Cxm/All.agda` зелёный, `cxm-server` собирается); `agdelte/src/Agdelte/FFI/` больше не
      содержит `Postgres.agda`; больше ничего в `src/` его не импортит (проверено грепом: только
      Migrate + 2 спайка → обновлены).

## Фаза B/C — фреймворк остаётся, аддоны → `~/agdelte-addons/` — ✅ DONE (2026-07-03)

Итог: фреймворк `agdelte` НЕ переезжал (уже свой репо `~/.agda/agdelte`). `agdelte-store` (+ pg),
`agdelte-auth`, `agdelte-payments` скопированы в `~/agdelte-addons/` (имена сохранены → `depend:`
у CXM/фреймворка не менялись). Оригиналы (git-репо) — в `~/.agda/_archive/` (история цела).

- [x] Копия store/auth/payments → `~/agdelte-addons/*` (rsync без `.git`/`_build`; diff = IDENTICAL).
- [x] Реестр `~/.agda/libraries` → пути на `~/agdelte-addons/`.
- [x] Пути перенастроены: `package.json` (gen:cxm-server + store-txn/rbac/yookassa/auth-client),
      `agdelte.cabal` `hs-source-dirs` → `/home/n/agdelte-addons/agdelte-store/hs`,
      `sergey-site/agdelte-web/build.sh` дефолты.
- [x] Оригиналы в `~/.agda/_archive/` (store 7 / auth 4 / payments 2 коммитов сохранены).
- **DoD ✅ (аудит+тесты 2026-07-03):** реестр 7/7 резолвится, граф ацикличен, архив вне реестра;
      CXM typecheck+стражи; `store-txn`/`rbac`/`yookassa` тесты PASS; `cxm-server`+`pg-spike`+
      `migrate-demo` собираются; live-smoke cxm-server (core+П3+П6+auth+pack) зелёный.

## Фаза D — снять префикс с CXM-либ — ✅ DONE (2026-07-03)

- [x] `agdelte-cxm` → `cxm`, `agdelte-pack-psych-cxm` → `cxm-pack-psych`: правка `name:` в `.agda-lib`
      + запись реестра + `depend: agdelte-cxm` у пака. **Имена модулей `Cxm.*`/`PsychCxm.*` НЕ трогать.**
- **DoD:** `agdelte-*` теперь однозначно = «в Agdelte-репо»; всё собирается.

## Порядок и риски

```
A (pg→store, на месте)  ← явный запрос; не требует новых репо; делать первым
B (Agdelte-репо)         ← фреймворк+auth; после A, чтобы pg уже был в store
C (store/payments репо)  ← вынести инфру; store уже самодостаточен (pg внутри)
D (переименование)       ← косметика namespace, в любой момент после C
E (FFI≠UI split)          ← НЕ в этом плане (Р6), отдельный крупный рефактор
```

- **ГЛАВНЫЙ УРОК АУДИТА — направление зависимости.** `agdelte → store` уже объявлено, поэтому в
  store едет ТОЛЬКО то, что не тянет фреймворк. Проверка перед любым переносом в store: «импортит
  ли модуль `Agdelte.FFI.*`/`Agdelte.Reactive.*`?» Если да — в store НЕЛЬЗЯ (цикл). Чистый драйвер
  (`Agda.Builtin.*`) — можно.
- **Риск A (харнесс) — вынужденный, не выбор:** спайки нужны Warp (`FFI.Server`) ⇒ их cabal остаётся
  в `agdelte`; правим только `hs-source-dirs`/`-i` на `store/hs` + `Storage.Postgres`. Плюс zlib-грабля
  NixOS (`LIBRARY_PATH` на libz) — как у `cxm-server`.
- **Риск namespace:** переименование `FFI.Postgres`→`Storage.Postgres` ломает импортёров — их РОВНО
  три (`Server.Migrate`, `PgSpike`, `MigrateDemo`; проверено грепом), обновить все до сборки.
- **Инвариант:** WAL-путь CXM трогать НЕЛЬЗЯ — после каждой фазы `Cxm.All`/`cxm-server` зелёные.
- Реестр `~/.agda/libraries` — единственный источник путей либ; правится в B/C/D, держать
  консистентным (имена либ = как в `depend:`; пути = актуальные).
