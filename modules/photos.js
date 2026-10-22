/* ═══════════════════════════════════════════════════════════════
   Dish photos — one list for the website, the QR table menu and the
   counter, so a dish looks the same everywhere. Matched by dish name;
   a dish with no photo here keeps its emoji (counter) or line icon
   (website).

   TPN_PHOTO(name)  → 'assets/site/dishes/….webp?v=…' or ''
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const PHOTOS = {
    'buttered shrimp': 'buttered-shrimp',
    'adobong pusit with gata': 'pusit-gata',
    'pares': 'pares',
    'beef caldereta': 'caldereta',
    'kare-kareng lechon kawali': 'kare-kare-lechon',
    'ginataang sitaw at kalabasa': 'ginataang-sitaw-kalabasa',
    'pork sisig': 'sisig',
    'teriyaki wings': 'teriyaki-wings',
    'laing': 'laing',
    'cornedbeef silog': 'cornedbeef-silog',
    'sisig silog': 'sisig-silog',
    'liemposilog': 'liempo-silog',
    'tapsilog': 'tapsilog',
    'tocilog': 'tocilog',
    'bacon silog': 'bacon-silog',
    'chicksilog': 'chicksilog',
    'calamares': 'calamares',
    'beef bistek': 'bistek',
    'pancit bihon': 'pancit-bihon',
    'ginataang hipon': 'ginataang-hipon',
  };
  // bump when a photo is replaced under the same name, or browsers keep the old one
  const PHOTO_V = '20261017f';
  window.TPN_PHOTO = (name) => { const k = PHOTOS[String(name || '').trim().toLowerCase()]; return k ? `assets/site/dishes/${k}.webp?v=${PHOTO_V}` : ''; };
})();
