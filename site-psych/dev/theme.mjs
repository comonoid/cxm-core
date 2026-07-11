/**
 * Ф5.1 — переключатель темы (данные, не код: тема = значение data-theme на <html>,
 * пресеты токенов — theme.css). Хранение: localStorage 'site-theme' (закладка §4 —
 * позже Resource rKind="theme"). Модуль отделён от страниц, чтобы смоук гонял его
 * в happy-dom как юнит.
 */
export function initTheme(win = globalThis.window) {
  const saved = win.localStorage.getItem('site-theme');
  if (saved) win.document.documentElement.setAttribute('data-theme', saved);
}

export function toggleTheme(win = globalThis.window) {
  const el = win.document.documentElement;
  const next = el.getAttribute('data-theme') === 'dark' ? '' : 'dark';
  if (next) el.setAttribute('data-theme', next);
  else el.removeAttribute('data-theme');
  win.localStorage.setItem('site-theme', next);
  return next;
}

// фикс-кнопка ◐ в углу; страницы зовут после маунта приложения
export function mountThemeToggle(win = globalThis.window) {
  initTheme(win);
  const d = win.document;
  const b = d.createElement('button');
  b.className = 'theme-toggle';
  b.textContent = '◐';
  b.title = 'светлая/тёмная тема';
  b.style.cssText = 'position:fixed;top:.6rem;right:.6rem;cursor:pointer;'
    + 'border:1px solid var(--s-border);background:var(--s-card);color:var(--s-fg);'
    + 'border-radius:50%;width:2rem;height:2rem;';
  b.onclick = () => toggleTheme(win);
  d.body.appendChild(b);
}
