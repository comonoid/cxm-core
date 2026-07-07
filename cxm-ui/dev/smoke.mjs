/**
 * Ф4.1-смоук: харнесс-путь без браузера — happy-dom + реальный fetch к ЖИВОМУ cxm-server-pg.
 * Это автоматическая половина «DOM — вручную»: монтирует clientCardApp через agdelte-рантайм,
 * кликает «Загрузить» → субъекта в ростере и ждёт реальные серверные round-trip'ы.
 * Визуальную полировку всё равно смотреть глазами в браузере (dev/serve.mjs + /dev/).
 *
 * Пререквизиты: scripts/pg-scratch.sh start + cxm-server-pg на 127.0.0.1:8138
 * (CXM_DEV=1). Сидит сам: register (идемпотентно 409) → login → субъект + 2 знания,
 * одно с kDetail work_strategy → проверяет панель VIII.a.
 *
 * Run: node dev/smoke.mjs   (из cxm-ui; happy-dom берётся из agdelte/node_modules)
 */
import { Window } from '/home/n/.agda/agdelte/node_modules/happy-dom/lib/index.js';

const API = process.env.CXM_API || 'http://127.0.0.1:8138';

// ── DOM-глобалы (как agdelte test/dom.test.js) ──────────────────────────────
const window = new Window({ url: 'http://localhost:8137' });
for (const k of ['document', 'HTMLElement', 'Element', 'Node', 'Text', 'Comment',
  'DOMException', 'MutationObserver', 'KeyboardEvent', 'MouseEvent']) globalThis[k] = window[k];
globalThis.window = window;
globalThis.requestAnimationFrame = (cb) => setTimeout(cb, 0);
globalThis.cancelAnimationFrame = (id) => clearTimeout(id);
// fetch НЕ подменяем: node-нативный, ходит на живой API (абсолютный base в Cfg)

const { runReactiveApp } = await import('/home/n/.agda/agdelte/runtime/reactive.js');
const Client = (await import('../_build/jAgda.CxmUI.Client.mjs')).default;
const Card = (await import('../_build/jAgda.CxmUI.ClientCard.mjs')).default;

let passed = 0, failed = 0;
const ok = (cond, name) => { if (cond) { console.log(`✓ ${name}`); passed++; }
                             else { console.log(`✗ ${name}`); failed++; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, what, ms = 5000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { const v = fn(); if (v) return v; await sleep(50); }
  throw new Error(`timeout: ${what}`);
}

// ── Сидинг через голый fetch (тот же живой сервер) ──────────────────────────
const post = async (path, body, jwt = '') =>
  (await fetch(API + path, { method: 'POST', body: JSON.stringify(body),
    headers: jwt ? { Authorization: 'Bearer ' + jwt } : {} })).json();

await post('/auth/register', { login: 'dev@cxm.local', password: 'devpass123', name: 'Dev Owner' }); // 409 ok
const token = (await post('/auth/login', { login: 'dev@cxm.local', password: 'devpass123' })
  .catch(() => ({}))).data?.token;
if (!token) { console.error('FATAL: нет живого cxm-server-pg на ' + API); process.exit(2); }
const subj = (await post('/subjects', { name: 'Смоук С.' }, token)).data.id;
const WS = '{"kind":"work_strategy","sync":false,"detail_first":true,"handoff_complete_when":"письмо с итогами"}';
await post('/knowledge', { subject: subj, detail: WS }, token);
await post('/knowledge', { subject: subj, detail: 'обычное наблюдение (не стратегия)' }, token);

// ── Монтаж виджета ровно как в харнессе ─────────────────────────────────────
const stage = document.createElement('div');
document.body.appendChild(stage);
const cfg = Client.mkCfg(API)(token);
await runReactiveApp({ app: Card.clientCardApp(cfg) }, stage);

ok(stage.querySelector('.cxm-client-card'), 'виджет смонтирован (cxm-client-card в DOM)');

stage.querySelector('.cxm-load').click();
await until(() => stage.querySelectorAll('.cxm-roster-btn').length > 0, 'ростер загрузился');
const btn = [...stage.querySelectorAll('.cxm-roster-btn')].find((b) => b.textContent === 'Смоук С.');
ok(btn, 'ростер: субъект «Смоук С.» пришёл с живого сервера');

btn.click();
await until(() => stage.querySelectorAll('.cxm-know').length >= 2, 'знания загрузились');
ok(true, 'карточка: знания выбранного субъекта загружены (2 шт.)');
ok(stage.querySelector('.cxm-badge-state'), 'эпист-бейдж типа отрендерен');

const panel = await until(() => stage.querySelector('.cxm-ws-panel'), 'панель VIII.a появилась');
const rows = panel.querySelectorAll('.cxm-ws');
ok(rows.length === 1, `панель VIII.a: ровно 1 стратегия (обычное знание отфильтровано), есть ${rows.length}`);
const phrase = panel.querySelector('.cxm-ws-text')?.textContent;
ok(phrase === 'асинхронно · сначала детали · хэндофф полон: письмо с итогами',
   `панель VIII.a: фраза читаемая («${phrase}»)`);
ok(panel.textContent.includes('Как достучаться'), 'панель VIII.a: заголовок «Как достучаться»');

// ── Ф3.1: лента (/v1, свой auth: integration token + identity) ──────────────
const Feed = (await import('../_build/jAgda.CxmUI.Feed.mjs')).default;
const itok = (await post('/integration-tokens', { origin: 'smoke' }, token)).data.token;
// сид соц-графа: автор публикует открытое + locked-тизер, зритель фолловит
const idOf = (ch, id) => ({ identity_channel: ch, identity_id: id });
const v1 = async (path, body) => (await fetch(API + path, { method: 'POST',
  body: JSON.stringify(body), headers: { 'x-integration-token': itok } })).json();
await v1('/v1/publish', { ...idOf('user_id', 'smoke-author'), payload: '{"text":"пост для смоука"}' });
await v1('/v1/publish', { ...idOf('user_id', 'smoke-author'), visibility: 'private', listing: 'public',
  payload: '{"text":"секрет"}' });
await v1('/v1/follow', { ...idOf('user_id', 'smoke-viewer'), target_channel: 'user_id', target_id: 'smoke-author' });

const feedStage = document.createElement('div');
document.body.appendChild(feedStage);
const v1cfg = Client.mkV1Cfg(API)(itok)('user_id')('smoke-viewer');
await runReactiveApp({ app: Feed.feedApp(v1cfg) }, feedStage);
feedStage.querySelector('.cxm-load').click();
await until(() => feedStage.querySelectorAll('.cxm-post').length >= 2, 'лента загрузилась');
const posts = [...feedStage.querySelectorAll('.cxm-post')];
ok(posts.some((p) => p.textContent.includes('пост для смоука')), 'лента: открытый пост с payload');
const locked = feedStage.querySelector('.cxm-post-locked');
ok(locked && locked.textContent.includes('🔒') && !locked.textContent.includes('секрет'),
   'лента: locked-пост — тизер-хром, payload зачищен');

// ── Ф3.2: тред (корень + ответ с parent, вкл. приватную реплику) ────────────
const Thread = (await import('../_build/jAgda.CxmUI.Thread.mjs')).default;
const rootId = (await v1('/v1/publish',
  { ...idOf('user_id', 'smoke-author'), payload: '{"text":"корень треда"}' })).data.id;
await v1('/v1/comment', { ...idOf('user_id', 'smoke-viewer'), anchor_kind: 'resource',
  anchor_id: rootId, parent: rootId, payload: '{"text":"публичный ответ"}' });
await v1('/v1/comment', { ...idOf('user_id', 'smoke-author'), anchor_kind: 'resource',
  anchor_id: rootId, parent: rootId, visibility: 'private', listing: 'public',
  payload: '{"text":"приватная реплика"}' });

const thStage = document.createElement('div');
document.body.appendChild(thStage);
await runReactiveApp({ app: Thread.threadApp(v1cfg)(BigInt(rootId)) }, thStage);
thStage.querySelector('.cxm-load').click();
await until(() => thStage.querySelectorAll('.cxm-thread-node').length >= 3, 'тред загрузился');
ok(thStage.querySelector('.cxm-depth-0')?.textContent.includes('корень треда'), 'тред: корень на depth-0');
ok([...thStage.querySelectorAll('.cxm-depth-1')].some((n) => n.textContent.includes('публичный ответ')),
   'тред: ответ на depth-1');
const lockedNode = thStage.querySelector('.cxm-node-locked');
ok(lockedNode && lockedNode.textContent.includes('🔒') && !lockedNode.textContent.includes('приватная'),
   'тред: закрытая реплика — тизер-стрип, payload зачищен');

// ── Ф3.3: витрина (полка + link с рангами, протухший validTo-слот исчезает) ─
const Showcase = (await import('../_build/jAgda.CxmUI.Showcase.mjs')).default;
const shelf = (await v1('/v1/publish',
  { ...idOf('user_id', 'smoke-author'), payload: '{"title":"полка"}' })).data.id;
const itemA = (await v1('/v1/publish',
  { ...idOf('user_id', 'smoke-author'), payload: '{"text":"слот А"}' })).data.id;
const itemB = (await v1('/v1/publish',
  { ...idOf('user_id', 'smoke-author'), payload: '{"text":"слот Б"}' })).data.id;
const itemGone = (await v1('/v1/publish',
  { ...idOf('user_id', 'smoke-author'), payload: '{"text":"протухший слот"}' })).data.id;
const link = (body) => post('/resources/link', body, token);
await link({ from: shelf, to: itemA, rank: 2 });
await link({ from: shelf, to: itemB, rank: 1 });
await link({ from: shelf, to: itemGone, rank: 3, validTo: 1 });   // окно давно закрыто

const shStage = document.createElement('div');
document.body.appendChild(shStage);
await runReactiveApp({ app: Showcase.showcaseApp(v1cfg)(BigInt(shelf)) }, shStage);
shStage.querySelector('.cxm-load').click();
await until(() => shStage.querySelectorAll('.cxm-post').length >= 2, 'витрина загрузилась');
const slots = [...shStage.querySelectorAll('.cxm-post')].map((s) => s.textContent);
ok(slots.length === 2 && slots[0].includes('слот Б') && slots[1].includes('слот А'),
   `витрина: rank-порядок (Б раньше А), слотов ${slots.length}`);
ok(!slots.some((s) => s.includes('протухший')), 'витрина: слот с истёкшим validTo исчез (проекция)');

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
