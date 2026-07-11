/**
 * Скин «calm» — Ф5.2, ПЕРВЫЙ КОНКРЕТНЫЙ медиа-скин (прежде движка скинов, П4-требования §3):
 * «скин как данные» — декларативный бандл {SVG-хром, CSS-спека раскладки}, никакого кода.
 * Хром — SVG-ОВЕРЛЕЙ ВОКРУГ НАТИВНОГО <video> (pointer-events:none — нативные controls
 * работают), не замена контента. Цвета — токенами темы (var(--s-accent)), скин живёт
 * в обеих темах. Расшаривание/продажа скинов («личный сайт за деньги») — потом,
 * с движком; хранение как Resource rKind="skin" — закладка §4.
 */
export default {
  name: 'calm',
  css: `
    .site-player { position: relative; display: inline-block; max-width: 100%;
                   border-radius: .6rem; overflow: hidden; }
    .site-player > video { display: block; border-radius: .6rem; margin: 0; }
    .site-player > .skin-chrome { position: absolute; inset: 0; pointer-events: none; }
  `,
  // рамка-волна: спокойная кайма + утолщение к углам
  chrome: `
    <svg class="skin-chrome" viewBox="0 0 100 100" preserveAspectRatio="none"
         xmlns="http://www.w3.org/2000/svg">
      <rect x="0.6" y="1" width="98.8" height="98" rx="2.2" fill="none"
            stroke="var(--s-accent)" stroke-width="1.6" opacity="0.85"/>
      <path d="M 2 12 Q 2 2 12 2" fill="none" stroke="var(--s-accent)"
            stroke-width="3.2" stroke-linecap="round"/>
      <path d="M 88 2 Q 98 2 98 12" fill="none" stroke="var(--s-accent)"
            stroke-width="3.2" stroke-linecap="round"/>
      <path d="M 98 88 Q 98 98 88 98" fill="none" stroke="var(--s-accent)"
            stroke-width="3.2" stroke-linecap="round"/>
      <path d="M 12 98 Q 2 98 2 88" fill="none" stroke="var(--s-accent)"
            stroke-width="3.2" stroke-linecap="round"/>
    </svg>
  `,
};
