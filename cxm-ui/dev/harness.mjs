// Дев-харнесс cxm-ui (Ф4.1): storybook-подобный каталог виджетов. Логин → JWT (sessionStorage),
// выбор виджета → runReactiveApp поверх agdelte-рантайма. Виджеты получают Cfg base=""
// (same-origin; dev/serve.mjs проксирует API-пути на живой cxm-server-pg).
import { runReactiveApp } from '/runtime/reactive.js';

// Каталог: одна запись на виджет; `app` строит ReactiveApp из модуля и Cfg.
// Новый виджет = новая строка здесь (+ его agda --js компилят в _build).
const WIDGETS = [
  { id: 'client-card', title: 'Карточка клиента (Ф2.1–2.6)',
    module: '/_build/jAgda.CxmUI.ClientCard.mjs',
    app: (mod, cfg) => mod.clientCardApp(cfg) },
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
  const cfg = client.default.mkCfg('')(jwt);   // base="" = same-origin (прокси serve.mjs)
  handle = await runReactiveApp({ app: w.app(mod.default, cfg) }, stage);
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
