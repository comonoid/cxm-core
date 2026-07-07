/**
 * site-psych Ф0-смоук: сайт ЦЕЛИКОМ (логин-форма → кабинет) против живого cxm-server-pg —
 * happy-dom, реальный fetch. Пререквизиты: pg-scratch + cxm-server-pg на :8138 (CXM_DEV=1)
 * и владелец dev@cxm.local/devpass123 (создаёт cxm-ui-смоук; или сам: register идемпотентен).
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

// кабинет живой: ростер грузится через site→zoomNode→Card→Client
stage.querySelector('.cxm-load').click();
await until(() => stage.querySelectorAll('.cxm-roster-btn').length > 0, 'ростер загрузился');
ok(true, 'Ф0: ростер грузится сквозь embedding (mapCmd/zoomNode работают)');

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
