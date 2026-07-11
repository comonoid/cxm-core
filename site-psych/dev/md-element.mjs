/**
 * <site-markdown data-md="…"> — рендер markdown docsify-СТЕКОМ: marked (движок docsify)
 * + DOMPurify (санитайз), вендорено в dev/vendor/. Agda-слой (SitePsych.Main) проносит
 * СЫРОЙ payload атрибутом — весь HTML-рендер живёт по эту сторону FFI-границы, фреймворк
 * и cxm-ui не трогаются. Полноценный docsify (страницы: mermaid/KaTeX-плагины, sidebar;
 * позже — вики) — обвязка ЗРИТЕЛЬСКОЙ страницы Ф3 поверх того же вендора (docsify.min.js).
 *
 * КОНТЕНТ-СХЕМЫ (site-plan Ф2.3): ссылки и медиа в payload — СУЩНОСТНЫЕ, не URL:
 *   [t](post:N | shelf:N | thread:N) → ROUTES (цели — роуты Ф3; внутренние БЕЗ target=_blank)
 *   ![](video:N)    → нативный <video controls src=/media/N> (доставка — П4c; скин — Ф5)
 *   ![](youtube:ID) → iframe СТРОГО по шаблону youtube-nocookie/embed/<ID> (ID валидируется;
 *                     произвольные iframe DOMPurify режет как резал)
 *
 * Санитайз: дефолты DOMPurify + наши схемы в ALLOWED_URI_REGEXP — <script>/onload/
 * javascript:-href вырезаются; ВНЕШНИМ ссылкам принудительно rel=noopener + target=_blank
 * (пост — чужой контент), внутренним — self.
 *
 * Работает и в браузере (dev/index.html), и в смоуке (happy-dom: customElements +
 * createNodeIterator есть) — импортировать ПОСЛЕ установки глобалей window/document.
 */
import { marked } from './vendor/marked.esm.js';
import DOMPurify from './vendor/purify.es.mjs';
import skin from './skins/calm.mjs';   // Ф5.2: медиа-скин (декларативный бандл, см. skins/)

const win = globalThis.window;
const purify = DOMPurify(win);

let skinCssInjected = false;
function applySkin(v) {                // SVG-хром ВОКРУГ нативного плеера (controls живые)
  const doc = v.ownerDocument;
  if (!skinCssInjected) {
    const st = doc.createElement('style');
    st.textContent = skin.css;
    doc.head.appendChild(st);
    skinCssInjected = true;
  }
  const wrap = doc.createElement('div');
  wrap.className = `site-player skin-${skin.name}`;
  v.replaceWith(wrap);
  wrap.appendChild(v);
  wrap.insertAdjacentHTML('beforeend', skin.chrome);
}

// дефолтный DOMPurify-regexp + наши сущностные/медиа-схемы
const ALLOWED_URI = /^(?:(?:(?:f|ht)tps?|mailto|tel|post|shelf|thread|video|youtube):|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|$))/i;

const ENTITY = /^(post|shelf|thread):(\d+)$/;
const VIDEO = /^video:(\d+)$/;
const YT = /^youtube:([\w-]{5,20})$/;
const OUR_SCHEME = /^(?:post|shelf|thread|video|youtube):/;

// цели схем: роуты зрительской страницы (Ф3); резолвер = конфиг ПОВЕРХНОСТИ —
// docsify-страницы передают свои (public.html#/post/N), площадка при синдикации
// подставит домен личного сайта (В3 deep-link)
export const DEFAULT_ROUTES = {
  post: (id) => `#/post/${id}`,
  shelf: (id) => `#/shelf/${id}`,
  thread: (id) => `#/thread/${id}`,
};

// П4c: src видео — ПОДПИСАННЫЙ URL из /v1/media-src (S7-гейт: автор/купил/публичное).
// Конфиг зрителя отдаёт обвязка страницы: window.siteV1 = {base, token, channel, id}.
// Без конфига/без прав — плеер деградирует в пометку «доступно после покупки».
async function resolveMediaSrc(v, id) {
  const cfg = win.siteV1 || {};
  try {
    const r = await fetch((cfg.base || '') + '/v1/media-src', { method: 'POST',
      headers: cfg.token ? { 'x-integration-token': cfg.token } : {},
      body: JSON.stringify({ identity_channel: cfg.channel || 'cookie',
                             identity_id: cfg.id || '', id: Number(id) }) });
    const j = await r.json();
    if (j.data?.url) { v.setAttribute('src', j.data.url); return; }
  } catch { /* сеть/нет конфига — падаем в locked-пометку */ }
  v.classList.add('site-media-locked');
  v.setAttribute('title', 'видео доступно после покупки');
}

// ЕДИНАЯ трансформация контент-схем над отрендеренным DOM — её зовут и <site-markdown>,
// и docsify-плагин страниц (pages.html, со СВОИМИ routes: public.html#/post/N).
export function applyContentSchemes(container, { routes = DEFAULT_ROUTES } = {}) {
  const doc = container.ownerDocument;
  for (const a of [...container.querySelectorAll('a[href]')]) {
    const href = a.getAttribute('href');
    const m = ENTITY.exec(href);
    if (m) {
      a.setAttribute('href', routes[m[1]](m[2]));   // внутренняя: роут поверхности, это же окно
      a.removeAttribute('target');
      a.removeAttribute('rel');
    } else if (OUR_SCHEME.test(href)) {
      a.removeAttribute('href');      // медиа-схема/битый id в роли ссылки → инертный текст
    } else if (/^https?:/i.test(href)) {
      a.setAttribute('rel', 'noopener');            // внешняя — в новое окно
      a.setAttribute('target', '_blank');
    }                                  // '#…'/относительные (docsify sidebar) — не трогаем
  }
  for (const img of [...container.querySelectorAll('img[src]')]) {
    const s = img.getAttribute('src') || '';
    let m;
    if ((m = VIDEO.exec(s))) {
      const v = doc.createElement('video');
      v.setAttribute('controls', '');
      v.setAttribute('preload', 'metadata');
      v.className = 'site-video';
      v.setAttribute('data-media', m[1]);
      img.replaceWith(v);
      applySkin(v);                    // Ф5.2: хром скина вокруг нативного плеера
      resolveMediaSrc(v, m[1]);        // П4c: подписанный src или locked-пометка
    } else if ((m = YT.exec(s))) {
      const f = doc.createElement('iframe');
      f.className = 'site-youtube';
      f.setAttribute('src', `https://www.youtube-nocookie.com/embed/${m[1]}`);
      f.setAttribute('allow', 'encrypted-media; picture-in-picture; fullscreen');
      img.replaceWith(f);
    }
  }
}

// <site-ts data-ts="unix-секунды"> — человеческое локальное время (даты рендерит JS-слой,
// Agda проносит только число; тот же шов, что <site-markdown>)
if (!win.customElements.get('site-ts')) {
  class SiteTs extends win.HTMLElement {
    static get observedAttributes() { return ['data-ts']; }
    connectedCallback() { this.renderTs(); }
    attributeChangedCallback() { this.renderTs(); }
    renderTs() {
      const ts = Number(this.getAttribute('data-ts') || '0');
      this.textContent = ts
        ? new Date(ts * 1000).toLocaleString('ru-RU',
            { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })
        : '';
    }
  }
  win.customElements.define('site-ts', SiteTs);
}

if (!win.customElements.get('site-markdown')) {
  class SiteMarkdown extends win.HTMLElement {
    static get observedAttributes() { return ['data-md']; }
    connectedCallback() { this.renderMd(); }
    attributeChangedCallback() { this.renderMd(); }
    renderMd() {
      const src = this.getAttribute('data-md') || '';
      const html = purify.sanitize(marked.parse(src), { ALLOWED_URI_REGEXP: ALLOWED_URI });
      this.innerHTML = `<div class="site-md">${html}</div>`;
      // схемы поверх санитизированного DOM: ссылки → роуты, ![](video:/youtube:) →
      // фиксированные шаблоны (никакого author-controlled HTML, только валидированный id)
      applyContentSchemes(this);
    }
  }
  win.customElements.define('site-markdown', SiteMarkdown);
}
