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

const win = globalThis.window;
const purify = DOMPurify(win);

// дефолтный DOMPurify-regexp + наши сущностные/медиа-схемы
const ALLOWED_URI = /^(?:(?:(?:f|ht)tps?|mailto|tel|post|shelf|thread|video|youtube):|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|$))/i;

const ENTITY = /^(post|shelf|thread):(\d+)$/;
const VIDEO = /^video:(\d+)$/;
const YT = /^youtube:([\w-]{5,20})$/;

// цели схем: роуты зрительской страницы (Ф3); резолвер = конфиг поверхности —
// площадка при синдикации подставит сюда домен личного сайта (В3 deep-link)
const ROUTES = {
  post: (id) => `#/post/${id}`,
  shelf: (id) => `#/shelf/${id}`,
  thread: (id) => `#/thread/${id}`,
};
const MEDIA_SRC = (id) => `/media/${id}`;   // контракт доставки — П4c (signed URL внутри)

const OUR_SCHEME = /^(?:post|shelf|thread|video|youtube):/;

purify.addHook('afterSanitizeAttributes', (node) => {
  if (node.tagName === 'A' && node.getAttribute('href')) {
    const href = node.getAttribute('href');
    const m = ENTITY.exec(href);
    if (m) {
      node.setAttribute('href', ROUTES[m[1]](m[2]));   // внутренняя: наш роут, это же окно
      node.removeAttribute('target');
      node.removeAttribute('rel');
    } else if (OUR_SCHEME.test(href)) {
      node.removeAttribute('href');   // медиа-схема/битый id в роли ссылки → инертный текст
    } else {
      node.setAttribute('rel', 'noopener');
      node.setAttribute('target', '_blank');
    }
  }
});

if (!win.customElements.get('site-markdown')) {
  class SiteMarkdown extends win.HTMLElement {
    static get observedAttributes() { return ['data-md']; }
    connectedCallback() { this.renderMd(); }
    attributeChangedCallback() { this.renderMd(); }
    renderMd() {
      const src = this.getAttribute('data-md') || '';
      const html = purify.sanitize(marked.parse(src), { ALLOWED_URI_REGEXP: ALLOWED_URI });
      this.innerHTML = `<div class="site-md">${html}</div>`;
      // медиа-схемы: ![](video:N)/![](youtube:ID) прошли санитайз как <img> — разворачиваем
      // в фиксированные шаблоны (никакого author-controlled HTML, только валидированный id)
      const doc = this.ownerDocument;
      for (const img of [...this.querySelectorAll('img')]) {
        const s = img.getAttribute('src') || '';
        let m;
        if ((m = VIDEO.exec(s))) {
          const v = doc.createElement('video');
          v.setAttribute('controls', '');
          v.setAttribute('preload', 'metadata');
          v.className = 'site-video';
          v.setAttribute('src', MEDIA_SRC(m[1]));
          img.replaceWith(v);
        } else if ((m = YT.exec(s))) {
          const f = doc.createElement('iframe');
          f.className = 'site-youtube';
          f.setAttribute('src', `https://www.youtube-nocookie.com/embed/${m[1]}`);
          f.setAttribute('allow', 'encrypted-media; picture-in-picture; fullscreen');
          img.replaceWith(f);
        }
      }
    }
  }
  win.customElements.define('site-markdown', SiteMarkdown);
}
