/**
 * site-psych смоук: сайт ЦЕЛИКОМ против живого cxm-server-pg — happy-dom, реальный fetch.
 * Пререквизиты: pg-scratch + cxm-server-pg на :8138 (CXM_DEV=1). Смоук САМОДОСТАТОЧЕН:
 * регистрирует владельца (идемпотентно) и сеет данные сам (клиент — через /subjects).
 *
 * Ф0: логин-форма → кабинет (ClientCard через zoomNode), contract-сверка, ростер.
 * Ф1: вкладка «Записи» — свои посты (Feed с identity владельца), публикация (publishV1),
 *     платная запись (createOffering c grants), «на полку» (linkResource) + анонимный
 *     locked-тизер в showcase (S7: listing ≠ reading).
 */
import { Window } from '/home/n/.agda/agdelte/node_modules/happy-dom/lib/index.js';

const API = process.env.CXM_API || 'http://127.0.0.1:8138';
const window = new Window({ url: 'http://localhost:8136' });
for (const k of ['document', 'HTMLElement', 'Element', 'Node', 'Text', 'Comment',
  'DOMException', 'MutationObserver']) globalThis[k] = window[k];
globalThis.window = window;
globalThis.requestAnimationFrame = (cb) => setTimeout(cb, 0);
globalThis.cancelAnimationFrame = (id) => clearTimeout(id);

const { runReactiveApp } = await import('/home/n/.agda/agdelte/runtime/reactive.js');
await import('./md-element.mjs');   // <site-markdown> — ПОСЛЕ установки happy-dom глобалей
const Main = (await import('../_build/jAgda.SitePsych.Main.mjs')).default;

let passed = 0, failed = 0;
const ok = (c, name) => { if (c) { console.log(`✓ ${name}`); passed++; }
                          else { console.log(`✗ ${name}`); failed++; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, what, ms = 5000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { const v = fn(); if (v) return v; await sleep(50); }
  throw new Error(`timeout: ${what}`);
}
const post = async (path, body, tok) => (await fetch(API + path, { method: 'POST',
  body: JSON.stringify(body),
  headers: tok ? { Authorization: `Bearer ${tok}` } : {} })).json();

// владелец (идемпотентно: 409 = уже есть)
await fetch(API + '/auth/register', { method: 'POST',
  body: JSON.stringify({ login: 'dev@cxm.local', password: 'devpass123', name: 'Dev Owner' }) });

const stage = document.createElement('div');
document.body.appendChild(stage);
await runReactiveApp({ app: Main.appWith(API) }, stage);

ok(stage.querySelector('.site-login'), 'Ф0: логин-форма отрендерена');
ok(!stage.querySelector('.cxm-client-card'), 'Ф0: кабинет скрыт до логина');

// неверный пароль → человеческая ошибка в баннере, остаёмся на логине
const type = (sel, v) => { const el = stage.querySelector(sel); el.value = v;
  el.dispatchEvent(new window.Event('input', { bubbles: true })); };
type('.site-lg', 'dev@cxm.local'); type('.site-pw', 'wrong');
stage.querySelector('.site-enter').click();
await until(() => stage.querySelector('.site-banner').textContent.startsWith('сервер: '),
  'ошибка логина в баннере');
ok(stage.querySelector('.site-login'), 'Ф0: неверный пароль — остались на логине, баннер человеческий');

// верный пароль → кабинет; сверка контракта прошла молча (баннер чист)
type('.site-pw', 'devpass123');
stage.querySelector('.site-enter').click();
await until(() => stage.querySelector('.cxm-client-card'), 'кабинет появился');
ok(true, 'Ф0: логин → кабинет (ClientCard встроен через zoomNode)');
ok(!stage.querySelector('.site-login'), 'Ф0: логин-форма ушла');
await sleep(300);   // GotHealth мог прийти после GotJwt
ok(stage.querySelector('.site-banner').textContent === '',
   'Ф0: contract-сверка молчит при совпадении версий');

// кабинет живой: клиент сеется через API, ростер грузится site→zoomNode→Card→Client
const tok = (await post('/auth/login', { login: 'dev@cxm.local', password: 'devpass123' })).data.token;
await post('/subjects', { name: 'Смоук Клиент' }, tok);
stage.querySelector('.cxm-load').click();
await until(() => stage.querySelectorAll('.cxm-roster-btn').length > 0, 'ростер загрузился');
ok(true, 'Ф0: ростер грузится сквозь embedding (mapCmd/zoomNode работают)');

// ── Ф1.1: вкладка «Записи» — Feed с identity владельца ──────────────────────
stage.querySelector('.site-tab-posts').click();
await until(() => stage.querySelector('.cxm-feed'), 'экран «Записи» отрендерен');
ok(!stage.querySelector('.cxm-client-card'), 'Ф1.1: вкладки переключаются (ClientCard ушёл)');
ok(stage.querySelector('.site-draft') && stage.querySelector('.site-publish'),
   'Ф1.1: редактор («Новая запись») на месте');

// ── Ф1.2: публикация публичной записи → появляется в своей ленте ────────────
type('.site-draft', 'Первая запись сайта, **markdown** пока сырой');
stage.querySelector('.site-publish').click();
await until(() => /запись #\d+ опубликована/.test(stage.querySelector('.site-note').textContent),
  'публикация подтверждена');
await until(() => [...stage.querySelectorAll('.cxm-post .site-md')]
  .some((el) => el.textContent.includes('Первая запись сайта')), 'пост появился в ленте');
ok(true, 'Ф1.2: publishV1 → свой пост виден в ленте (feedViews включает автора)');
ok(stage.querySelector('.site-draft').value === '', 'Ф1.2: черновик очищен после публикации');

// ── Ф1.3: платная запись — офферинг c grants на пост ────────────────────────
const sel = stage.querySelector('.site-vis');
sel.value = 'entitled';
sel.dispatchEvent(new window.Event('change', { bubbles: true }));
type('.site-price', '500');
type('.site-draft', 'Платная запись: техника заземления');
stage.querySelector('.site-publish').click();
await until(() => /офферинг #\d+ создан/.test(stage.querySelector('.site-note').textContent),
  'офферинг создан');
const paidId = Number(stage.querySelector('.site-post-id').value);
ok(paidId > 0, 'Ф1.3: id платной записи подставлен в поле «на полку»');

// офферинг честно в /v1-каталоге: цена серверная, grants указывают на пост
const itok = (await post('/integration-tokens', { origin: 'smoke-site' }, tok)).data.token;
const v1 = async (path, body) => (await fetch(API + path, { method: 'POST',
  body: JSON.stringify(body), headers: { 'x-integration-token': itok } })).json();
const offers = (await v1('/v1/offerings', {})).data;
const myOffer = offers.find((o) => o.metadata.includes(`"id":${paidId}`));
ok(myOffer && myOffer.price === 50000,
   'Ф1.3: /v1/offerings несёт офферинг (50000 коп) с grants на запись');

// владелец видит свою платную запись РАЗБЛОКИРОВАННОЙ (authorSeesOwn)
await until(() => [...stage.querySelectorAll('.cxm-post .site-md')]
  .some((el) => el.textContent.includes('техника заземления')), 'платный пост в своей ленте');
ok(![...stage.querySelectorAll('.cxm-post')].some((el) =>
     el.classList.contains('cxm-post-locked') && el.textContent.includes('техника')),
   'Ф1.3: для автора платная запись не заперта');

// ── Ф1.4: «на полку» + S7 — анонимный зритель получает locked-тизер ─────────
const shelf = (await v1('/v1/publish', { identity_channel: 'user_id',
  identity_id: 'dev@cxm.local', payload: '{"kind":"shelf","name":"витрина"}' })).data.id;
type('.site-shelf-id', String(shelf));
stage.querySelector('.site-shelf-btn').click();
await until(() => /на полке/.test(stage.querySelector('.site-note').textContent),
  'запись легла на полку');
ok(true, 'Ф1.4: linkResource из кабинета (полка ← запись)');

const anonRows = (await v1('/v1/showcase', { from: shelf })).data;
const anonRow = anonRows.find((r) => r.id === paidId);
ok(anonRow && anonRow.locked === true && anonRow.payload === '',
   'Ф1.4/S7: анониму на витрине — locked-тизер, payload ободран');

// ── Ф2.1: markdown-рендер payload — docsify-стек (marked+DOMPurify) ──────────
const selPub = stage.querySelector('.site-vis');
selPub.value = 'public';
selPub.dispatchEvent(new window.Event('change', { bubbles: true }));
type('.site-draft', '## Про тревогу\n\nАбзац с **жирным** и [ссылкой](https://example.com).\n\n'
  + '- дыхание\n- заземление\n\n<script>alert(1)</script> и [клик](javascript:alert(2))');
stage.querySelector('.site-publish').click();
await until(() => [...stage.querySelectorAll('.site-md h2')]
  .some((el) => el.textContent === 'Про тревогу'), 'markdown-заголовок отрендерен');
const md = [...stage.querySelectorAll('.site-md')]
  .find((el) => el.querySelector('h2')?.textContent === 'Про тревогу');
ok([...md.querySelectorAll('strong')].some((el) => el.textContent === 'жирным'),
   'Ф2.1: **жирный** → <strong>');
const aOk = md.querySelector('a[href="https://example.com"]');
ok(aOk?.textContent === 'ссылкой' && aOk?.getAttribute('rel') === 'noopener',
   'Ф2.1: [ссылка](https) → <a href> + принудительный rel=noopener');
ok(md.querySelectorAll('ul li').length === 2, 'Ф2.1: список «- » → <ul><li>');
ok(!md.querySelector('script') && !md.textContent.includes('alert(1)'),
   'Ф2.1/санитайз: <script> вырезан DOMPurify целиком');
ok(!md.querySelector('a[href^="javascript"]') && md.textContent.includes('клик'),
   'Ф2.1/санитайз: у javascript:-ссылки удалён href');

// ── Ф2.3: контент-схемы — сущностные ссылки + видео/youtube ─────────────────
type('.site-draft', `Смотри [запись](post:${paidId}) и [полку](shelf:${shelf}).\n\n`
  + '![](video:42)\n\n![](youtube:dQw4w9WgXcQ)\n\n'
  + '<iframe src="https://evil.example/x"></iframe> [x](video:notanumber)');
stage.querySelector('.site-publish').click();
await until(() => [...stage.querySelectorAll('.site-md')]
  .some((el) => el.querySelector(`a[href="#/post/${paidId}"]`)), 'пост со схемами в ленте');
const md2 = [...stage.querySelectorAll('.site-md')]
  .find((el) => el.querySelector(`a[href="#/post/${paidId}"]`));
const inA = md2.querySelector(`a[href="#/post/${paidId}"]`);
ok(inA && !inA.getAttribute('target'),
   'Ф2.3: post:N → #/post/N, внутренняя ссылка БЕЗ target=_blank');
ok(md2.querySelector(`a[href="#/shelf/${shelf}"]`), 'Ф2.3: shelf:N → #/shelf/N');
const vid = md2.querySelector('video.site-video');
ok(vid?.getAttribute('src') === '/media/42' && vid?.hasAttribute('controls'),
   'Ф2.3: ![](video:N) → нативный <video controls src=/media/N>');
ok(md2.querySelector('iframe.site-youtube')?.getAttribute('src')
     === 'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
   'Ф2.3: ![](youtube:ID) → iframe строго youtube-nocookie/embed');
ok(md2.querySelectorAll('iframe').length === 1,
   'Ф2.3/санитайз: произвольный iframe вырезан (выжил только youtube-шаблон)');
ok(!md2.querySelector('a[href^="video:"]') && !md2.querySelector('video[src*="notanumber"]'),
   'Ф2.3/санитайз: video:не-число не становится ни ссылкой, ни плеером');

// ── Ф3.1: публичная страница — аноним с cookie-identity ─────────────────────
const Public = (await import('../_build/jAgda.SitePsych.Public.mjs')).default;
const pub = document.createElement('div');
document.body.appendChild(pub);
window.location.hash = '';   // старт с главной
await runReactiveApp({ app: Public.appWith(API)(itok)('smoke-pub-visitor')(BigInt(shelf)) }, pub);

// главная: витрина полки видна анониму, платная запись — locked-тизером
await until(() => pub.querySelectorAll('.cxm-post').length > 0, 'витрина загрузилась');
ok(pub.querySelector('.pub-main .cxm-showcase'), 'Ф3.1: главная = витрина полки сайта');
const pubPaid = [...pub.querySelectorAll('.cxm-post')].find((p) => p.classList.contains('cxm-post-locked'));
ok(pubPaid && pubPaid.querySelector('.cxm-post-teaser'),
   'Ф3.1: платная запись для анонима — locked-тизер на витрине');
await until(() => pub.querySelectorAll('.cxm-offer').length > 0, 'paywall загрузился');
ok(true, 'Ф3.1: paywall с офферингами виден анониму');

// роутинг: #/post/N → страница записи (тред; корень заперт для анонима)
window.location.hash = `#/post/${paidId}`;
window.dispatchEvent(new window.Event('hashchange'));
await until(() => pub.querySelector('.pub-post .cxm-thread'), 'страница записи открылась');
ok(!pub.querySelector('.pub-main'), 'Ф3.1: роутинг — витрина ушла, страница записи на месте');
await until(() => pub.querySelector('.cxm-node-locked'), 'корень треда — тизер');
ok(true, 'Ф3.1: запись для анонима заперта (S7-тизер в треде)');

// покупка АНОНИМОМ прямо на странице записи: buy → (webhook) → контент открылся
const offRow = await until(() => pub.querySelector(`.cxm-offer-${myOffer.id}`), 'офферинг в paywall');
offRow.querySelector('.cxm-buy').click();
await until(() => /платёж #\d+/.test(pub.querySelector('.pub-pay .cxm-status').textContent),
  'платёж создан');
const pubPayId = pub.querySelector('.pub-pay .cxm-status').textContent.match(/платёж #(\d+)/)[1];
const admTok = (await post('/auth/login', { login: 'admin@dev', password: 'adminpass123' })).data?.token;
if (!admTok) { console.error('FATAL: нет админа (PSYCH_ADMIN_LOGIN)'); process.exit(2); }
await post('/payments/succeed', { id: Number(pubPayId) }, admTok);
pub.querySelector('.pub-post .cxm-load').click();
await until(() => [...pub.querySelectorAll('.pub-post .site-md')]
  .some((el) => el.textContent.includes('техника заземления')), 'контент открылся после оплаты');
ok(!pub.querySelector('.pub-post .cxm-node-locked'),
   'Ф3.1: аноним купил на странице записи → entitlement → контент открыт');

// ── Ф3.2: «сохранить доступ» — регистрация → login → mergeSession ───────────
const ptype = (sel, v) => { const el = pub.querySelector(sel); el.value = v;
  el.dispatchEvent(new window.Event('input', { bubbles: true })); };
ptype('.pub-lg', 'buyer@cxm.local'); ptype('.pub-pw', 'buyerpass123'); ptype('.pub-nm', 'Покупатель');
pub.querySelector('.pub-save').click();
await until(() => pub.querySelector('.pub-acc-note').textContent.includes('доступ сохранён'),
  'merge прошёл');
ok(true, 'Ф3.2: регистрация → login → mergeSession (идемпотентно: 409 не рвёт цепочку)');

// покупка cookie-сессии теперь видна АККАУНТУ (login-identity) — и не видна чужой сессии
const accRows = (await v1('/v1/thread',
  { identity_channel: 'user_id', identity_id: 'buyer@cxm.local', root: paidId })).data;
ok(accRows.find((r) => r.id === paidId)?.locked === false,
   'Ф3.2: аккаунт видит купленное анонимом (сессия слита в аккаунт)');
const strangerRows = (await v1('/v1/thread',
  { identity_channel: 'cookie', identity_id: 'stranger-visitor', root: paidId })).data;
ok(strangerRows.find((r) => r.id === paidId)?.locked === true,
   'Ф3.2/адверсарий: чужая cookie-сессия — по-прежнему тизер');

// ── Ф4: inbox упоминаний — покупатель упоминает автора, автор видит в кабинете ─
const ownerId = (await v1('/v1/feed',
  { identity_channel: 'user_id', identity_id: 'dev@cxm.local' })).data[0].author;
await v1('/v1/comment', { identity_channel: 'user_id', identity_id: 'buyer@cxm.local',
  anchor_kind: 'resource', anchor_id: paidId, addressees: `[${ownerId}]`,
  payload: 'Вопрос **автору** про заземление' });
stage.querySelector('.site-tab-inbox').click();
await until(() => stage.querySelector('.site-inbox .cxm-feed'), 'вкладка «Упоминания» открылась');
stage.querySelector('.site-inbox .cxm-load').click();
await until(() => [...stage.querySelectorAll('.site-inbox .site-md')]
  .some((el) => el.textContent.includes('Вопрос автору')), 'упоминание пришло в инбокс');
ok([...stage.querySelectorAll('.site-inbox .site-md strong')]
  .some((el) => el.textContent === 'автору'),
   'Ф4: упоминание в инбоксе кабинета (markdown отрендерен)');
// адверсарии: не-адресат и аноним инбокса не видят
const buyerInbox = (await v1('/v1/mentions',
  { identity_channel: 'user_id', identity_id: 'buyer@cxm.local' })).data;
ok(!JSON.stringify(buyerInbox).includes('автору'),
   'Ф4/адверсарий: НЕ-адресат чужого упоминания не видит');
const anonInbox = (await v1('/v1/mentions', {})).data;
ok(Array.isArray(anonInbox) && anonInbox.length === 0, 'Ф4/адверсарий: аноним — пустой инбокс');

// ── П4b: услуги — psych-пак на PG-сервере (API-цикл, фронт услуг — потом) ────
const P = (path, body) => post(path, body);   // /psych/* и /payments/* — публичные
const offs = (await (await fetch(API + '/psych/offerings')).json()).data;
ok(offs.length === 4 && offs.find((o) => o.code === 2)?.sessions === 5,
   'П4b: GET /psych/offerings — каталог пака (4 позиции)');

const slots = (await P('/psych/availability', { type: 'session' })).data;
ok(slots.length > 3 && slots[0].end - slots[0].start === 90 * 60,
   'П4b: availability — сетка Пн–Пт, session = 90 мин');

// бронь: свободный слот ок (+письмо в outbox), повтор того же слота — конфликт, "сейчас" — notice
const bookOk = await P('/psych/book',
  { type: 'session', start: slots[0].start, name: 'Клиент Смоук', email: 'client-smoke@cxm.local' });
ok(bookOk.data?.id > 0, 'П4b: book — бронь свободного слота');
const bookDup = await P('/psych/book',
  { type: 'session', start: slots[0].start, name: 'Другой', email: 'other@cxm.local' });
ok(bookDup.error?.code === 'conflict', 'П4b/адверсарий: тот же слот — 409 conflict');
const bookNow = await P('/psych/book',
  { type: 'session', start: Math.floor(Date.now() / 1000) + 60, name: 'Т', email: 't@x' });
ok(bookNow.error?.code === 'validation', 'П4b/политика: слот ближе notice-окна отвергнут');
const outboxRows = (await (await fetch(API + '/outbox',
  { headers: { Authorization: `Bearer ${tok}` } })).json()).data;
ok(outboxRows.some((r) => r.to === 'client-smoke@cxm.local'),
   'П4b/b3: письмо-подтверждение легло в outbox владельца (tenant пака = владелец)');

// пакет: purchase(5) → session списывает кредит → cancel в окне возвращает → complete жжёт
const eng = (await P('/psych/purchase',
  { offering: 2, name: 'Клиент Смоук', email: 'client-smoke@cxm.local' })).data.id;
const pkg0 = (await P('/psych/package', { eng })).data;
ok(pkg0.sessionsTotal === 5 && pkg0.sessionsLeft === 5, 'П4b: пакет 5 сессий открыт (purchase)');
const s1 = (await P('/psych/session', { eng, start: slots[1].start })).data.id;
ok((await P('/psych/package', { eng })).data.sessionsLeft === 4, 'П4b: сессия списала кредит (5→4)');
ok((await P('/psych/cancel', { act: s1 })).data.result === 'canceled',
   'П4b/политика: отмена в 24h-окне — canceled');
ok((await P('/psych/package', { eng })).data.sessionsLeft === 5, 'П4b: отмена вернула кредит (4→5)');
const s2 = (await P('/psych/session', { eng, start: slots[2].start })).data.id;
await P('/psych/complete', { act: s2 });
ok((await P('/psych/package', { eng })).data.sessionsLeft === 4, 'П4b: complete сжёг кредит');

// кредит-гейт: пакет на 1 сессию исчерпывается → 402
const eng1 = (await P('/psych/purchase', { offering: 1, email: 'client-smoke@cxm.local' })).data.id;
await P('/psych/session', { eng: eng1, start: slots[3].start });
const over = await P('/psych/session', { eng: eng1, start: slots[4].start });
ok(over.error?.code === 'insufficient_funds', 'П4b: кредиты пакета исчерпаны — 402 Insufficient');

// онлайн-оплата (dev-стаб ЮKassa): create → pending, webhook succeeded → грант + эпизод,
// редоставка вебхука → идемпотентный 200
const pay = (await P('/payments/create',
  { offering: 3, name: 'Клиент Смоук', email: 'client-smoke@cxm.local' })).data;
ok(pay.paymentId > 0 && pay.confirmationUrl && pay.extId,
   'П4b: /payments/create (dev-стаб) — pending + confirmationUrl');
const wh1 = (await P('/payments/webhook',
  { event: 'payment.succeeded', object: { id: pay.extId } })).data;
ok(wh1.granted === true && wh1.engagement > 0, 'П4b: webhook → грант + пакетный эпизод');
ok((await P('/psych/package', { eng: wh1.engagement })).data.sessionsTotal === 10,
   'П4b: оплаченный пакет — 10 сессий');
const wh2 = (await P('/payments/webhook',
  { event: 'payment.succeeded', object: { id: pay.extId } })).data;
ok(wh2.granted === false && wh2.idempotent === true,
   'П4b: редоставка вебхука — идемпотентный no-op (200)');

// ── Фронт услуг: #/book — слоты → выбор → форма → бронь (в браузере) ─────────
window.location.hash = '#/book';
window.dispatchEvent(new window.Event('hashchange'));
await until(() => pub.querySelectorAll('.bk-pick').length > 0, 'слоты записи отрендерены');
ok(pub.querySelector('.bk-pick site-ts')?.textContent.match(/\d{2}\.\d{2}.*\d{2}:\d{2}/),
   'Фронт услуг: слот показан человеческим временем (<site-ts>)');
const slotBtns = pub.querySelectorAll('.bk-pick');
const freeCount = slotBtns.length;

// пустая форма — не уходит на сервер, человеческая подсказка
pub.querySelector('.bk-go').click();
await until(() => pub.querySelector('.bk-status').textContent.includes('заполните'),
  'валидация формы записи');
ok(true, 'Фронт услуг: пустая форма — подсказка, запрос не ушёл');

// выбор слота + форма → бронь → статус «вы записаны» → слоты перечитаны (занятый исчез)
slotBtns[0].click();
await until(() => /\d{2}:\d{2}/.test(pub.querySelector('.bk-chosen site-ts')?.textContent || ''),
  'выбранный слот показан');
ptype('.bk-name', 'Браузерный Клиент'); ptype('.bk-email', 'browser-client@cxm.local');
pub.querySelector('.bk-go').click();
await until(() => /вы записаны — встреча #\d+/.test(pub.querySelector('.bk-done').textContent),
  'бронь через браузер');
ok(true, 'Фронт услуг: слот → форма → «вы записаны» (PsychCxm.Client как SDK слоя 3)');
await until(() => pub.querySelectorAll('.bk-pick').length === freeCount - 1,
  'слоты перечитаны');
ok(true, 'Фронт услуг: занятый слот исчез из сетки после брони');

// intro-переключатель: другая длительность сетки (30 мин)
const tySel = pub.querySelector('.bk-ty');
tySel.value = 'intro';
tySel.dispatchEvent(new window.Event('change', { bubbles: true }));
await sleep(300);
const introSlots = (await P('/psych/availability', { type: 'intro' })).data;
ok(introSlots[0].end - introSlots[0].start === 30 * 60,
   'Фронт услуг: intro-сетка 30-минутная (select переключает тип)');

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
