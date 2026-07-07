// Дев-харнесс cxm-ui (Ф4.1): storybook-подобный каталог виджетов. Логин → JWT (sessionStorage),
// выбор виджета → runReactiveApp поверх agdelte-рантайма. Виджеты получают Cfg base=""
// (same-origin; dev/serve.mjs проксирует API-пути на живой cxm-server-pg).
import { runReactiveApp } from '/runtime/reactive.js';

// Каталог: одна запись на виджет; `app(mod, ctx)` строит ReactiveApp (может быть async —
// напр. минтит integration-token для /v1). ctx = { jwt, client } (client = jAgda-модуль Client).
// Новый виджет = новая строка здесь (+ его agda --js компилят в _build).
const WIDGETS = [
  { id: 'client-card', title: 'Карточка клиента (Ф2.1–2.6)',
    module: '/_build/jAgda.CxmUI.ClientCard.mjs',
    app: (mod, ctx) => mod.clientCardApp(ctx.client.mkCfg('')(ctx.jwt)) },
  { id: 'feed', title: 'Лента (Ф3.1)',
    module: '/_build/jAgda.CxmUI.Feed.mjs',
    app: async (mod, ctx) => {
      const r = await fetch('/integration-tokens', { method: 'POST',
        headers: { Authorization: 'Bearer ' + ctx.jwt }, body: JSON.stringify({ origin: 'harness' }) });
      const itok = (await r.json()).data.token;
      return mod.feedApp(ctx.client.mkV1Cfg('')(itok)('user_id')('dev-viewer'));
    } },
  { id: 'thread', title: 'Тред (Ф3.2)',
    module: '/_build/jAgda.CxmUI.Thread.mjs',
    app: async (mod, ctx) => {
      const r = await fetch('/integration-tokens', { method: 'POST',
        headers: { Authorization: 'Bearer ' + ctx.jwt }, body: JSON.stringify({ origin: 'harness' }) });
      const itok = (await r.json()).data.token;
      const root = window.prompt('id корневого ресурса треда', '21') || '0';
      return mod.threadApp(ctx.client.mkV1Cfg('')(itok)('user_id')('dev-viewer'))(BigInt(root));
    } },
];

let jwt = sessionStorage.getItem('cxm-jwt') || '';
let current = null;   // выбранный виджет
let handle = null;    // результат runReactiveApp (для unmount при переключении)

const $ = (id) => document.getElementById(id);
const whoami = () => { $('whoami').textContent = jwt ? 'JWT получен ✓' : 'не залогинен'; };

async function mount(w) {
  current = w;
  for (const b of document.querySelectorAll('#catalog button'))
    b.classList.toggle('active', b.dataset.id === w.id);
  const stage = $('stage');
  if (handle && handle.unmount) handle.unmount();
  stage.replaceChildren();
  if (!jwt) { stage.innerHTML = '<p class="hint">сначала войди — виджетам нужен Bearer</p>'; return; }
  const [mod, client] = await Promise.all([
    import(w.module), import('/_build/jAgda.CxmUI.Client.mjs')]);
  // base="" = same-origin (прокси serve.mjs)
  const app = await w.app(mod.default, { jwt, client: client.default });
  handle = await runReactiveApp({ app }, stage);
}

$('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const r = await fetch('/auth/login', {
    method: 'POST',
    body: JSON.stringify({ login: $('lg').value, password: $('pw').value }) });
  const j = await r.json().catch(() => ({}));
  if (j.data?.token) {                      // live shape: {"data":{"token":…}}
    jwt = j.data.token; sessionStorage.setItem('cxm-jwt', jwt); whoami();
    if (current) mount(current);
  } else {
    $('whoami').textContent = 'логин не удался: ' + (j.error?.message || r.status);
  }
});

const nav = $('catalog');
for (const w of WIDGETS) {
  const b = document.createElement('button');
  b.textContent = w.title; b.dataset.id = w.id;
  b.addEventListener('click', () => mount(w));
  nav.appendChild(b);
}
whoami();
if (jwt) mount(WIDGETS[0]);
