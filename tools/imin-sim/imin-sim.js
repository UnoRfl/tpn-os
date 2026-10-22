#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════
   TPN iMin simulator — the counter's hardware, on any PC.

   Stands in for everything TPN OS talks to on the iMin D4-504, so the
   real pages can be tested on a laptop or desktop with no install:

     127.0.0.1:8081   iMin's "iMinprinterplugin" print service
                      (WebSocket /websocket + POST /upload, the protocol
                      of vendor/imin-printer-1.4.0.min.js): receipts,
                      kitchen tickets, bills, picture slips, QR codes,
                      the cash drawer, printer status (ready, paper out,
                      cover open, plugin missing)
     127.0.0.1:8091   the TPN Counter app's loopback link
                      (CustomerScreenService): /ping, /state (rear
                      screen), /print (the kitchen network printer)
     127.0.0.1:7070   the dashboard: both printers' paper rolls, the
                      drawer, the rear screen's state, switches for
                      every hardware fault
     127.0.0.1:7071   (with --local) your working copy of the site

   It opens the counter (1920×1080 or 1280×720) and the rear customer
   screen (1280×800) as two app windows in one browser profile, with
   the app's user agent, so the page behaves as it does on the iMin.

   Node 18+ and Chrome, Edge or Firefox. No packages to install.
     node tools/imin-sim/imin-sim.js                 live site
     node tools/imin-sim/imin-sim.js --local         this folder's copy
     node tools/imin-sim/imin-sim.js --help          every option
   Full guide: HARDWARE.md, "The iMin simulator".
   ═══════════════════════════════════════════════════════════════ */
'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');
const zlib = require('zlib');
const { spawn, execFileSync } = require('child_process');

/* ── Options ─────────────────────────────────────────────────── */
const ROOT = path.resolve(__dirname, '..', '..');
const argv = process.argv.slice(2);
const flag = (n) => argv.includes('--' + n);
const opt = (n, d) => { const i = argv.indexOf('--' + n); return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : d; };
if (flag('help') || flag('h')) {
  console.log(`TPN iMin simulator

  --local [dir]        serve a working copy (default: this repo) at http://127.0.0.1:7071/
                       and open that instead of the live site
  --site URL           site to open (default https://unorfl.github.io/tpn-os/)
  --screen 1080|720    counter window: 1920x1080 (default) or 1280x720 (density 1.5)
  --browser chrome|edge|firefox|none   which browser to open (default: chrome, else edge)
  --browser-path PATH  exact browser program
  --kitchen            also open the kitchen station (TPN Kitchen user agent)
  --no-rear            don't open the rear customer screen
  --lite off           don't force the iMin's light drawing mode (html.tpn-lite)
  --version 1.4.0      app version in the user agent (default 1.4.0)
  --fresh              start from an empty browser profile (signed out, settings cleared)
`);
  process.exit(0);
}
const LOCAL = flag('local');
const LOCAL_DIR = (() => { const v = opt('local', ''); return v ? path.resolve(v) : ROOT; })();
const SITE = (() => {
  if (LOCAL) return 'http://127.0.0.1:7071/';
  let s = opt('site', 'https://unorfl.github.io/tpn-os/');
  return s.endsWith('/') ? s : s + '/';
})();
const SCREEN = opt('screen', '1080') === '720' ? { w: 1280, h: 720, dpr: 1.5 } : { w: 1920, h: 1080, dpr: 1 };
const REAR = { w: 1280, h: 800 };
const VERSION = opt('version', '1.4.0');
const PROFILE_DIR = path.join(os.homedir(), '.tpn-imin-sim');
// The apps run GeckoView 153 and add "TPNCounter/<version>" (MainActivity.java).
const UA = (tag) => `Mozilla/5.0 (Android 11; Mobile; rv:153.0) Gecko/153.0 Firefox/153.0 ${tag}/${VERSION}`;

/* ── Shared state + live events for the dashboard ────────────── */
const sim = {
  printer: 'ready',      // ready | paper | cover | off (plugin not installed)
  relay: 'on',           // on | off (an app older than 1.4 / Chrome without the app)
  kitchen: 'ready',      // ready | off (kitchen printer unplugged or wrong address)
  slow: 0,               // ms added to every print (a busy printer)
};
const clients = new Set();
const history = [];
function emit(type, data) {
  const ev = { type, at: Date.now(), ...data };
  history.push(ev); if (history.length > 300) history.shift();
  const line = `data: ${JSON.stringify(ev)}\n\n`;
  for (const res of clients) { try { res.write(line); } catch (e) { clients.delete(res); } }
  if (type !== 'state') console.log(`[${new Date().toLocaleTimeString()}] ${type}${data.note ? ' · ' + data.note : ''}`);
}

/* ── CORS: the live site, your local copy, and localhost tools ── */
function allowedOrigin(o) {
  if (!o) return null;
  try {
    const u = new URL(o);
    if (u.hostname === '127.0.0.1' || u.hostname === 'localhost') return o;
    if (o === new URL(SITE).origin) return o;
    if (o === 'https://unorfl.github.io') return o;
  } catch (e) {}
  return null;
}
function cors(req, res) {
  const o = allowedOrigin(req.headers.origin);
  if (o) {
    res.setHeader('Access-Control-Allow-Origin', o);
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'content-type');
    res.setHeader('Access-Control-Allow-Private-Network', 'true');
    res.setHeader('Vary', 'Origin');
  }
  return !!o || !req.headers.origin;
}
const readBody = (req, max = 16 * 1024 * 1024) => new Promise((ok, no) => {
  const parts = []; let n = 0;
  req.on('data', (c) => { n += c.length; if (n > max) { no(new Error('too big')); req.destroy(); } else parts.push(c); });
  req.on('end', () => ok(Buffer.concat(parts)));
  req.on('error', no);
});

/* ── A tiny PNG encoder (for ESC/POS pictures from the kitchen) ── */
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc32(buf) { let c = 0xFFFFFFFF; for (const b of buf) c = CRC[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; }
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png1bit(rows, widthBytes) {   // rows: Buffers, set bit = black dot
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(widthBytes * 8, 0); ihdr.writeUInt32BE(rows.length, 4);
  ihdr[8] = 1; ihdr[9] = 0; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  const raw = Buffer.concat(rows.map((r) => Buffer.concat([Buffer.from([0]), Buffer.from(r.map((b) => 255 - b))])));
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
// ESC/POS as sent by modules/kprint.js: ESC @, GS v 0 bands, feed, cut.
function escposToPng(buf) {
  const rows = []; let w = 0, i = 0, text = '';
  while (i < buf.length) {
    if (buf[i] === 0x1B && buf[i + 1] === 0x40) { i += 2; continue; }                       // init
    if (buf[i] === 0x1D && buf[i + 1] === 0x76 && buf[i + 2] === 0x30) {                     // raster
      const bw = buf[i + 4] | (buf[i + 5] << 8), h = buf[i + 6] | (buf[i + 7] << 8); i += 8; w = bw;
      for (let y = 0; y < h; y++) { rows.push(buf.subarray(i, i + bw)); i += bw; }
      continue;
    }
    if (buf[i] === 0x1B && buf[i + 1] === 0x64) { i += 3; continue; }                       // feed n lines
    if (buf[i] === 0x1D && buf[i + 1] === 0x56) { i += buf[i + 2] >= 65 ? 4 : 3; continue; } // cut
    if (buf[i] >= 0x20 && buf[i] < 0x7F || buf[i] === 0x0A) text += String.fromCharCode(buf[i]);
    i++;
  }
  return { png: rows.length ? png1bit(rows, w) : null, dots: w * 8, height: rows.length, text: text.trim() };
}

/* ── 8081: iMin's print service ───────────────────────────────
   Messages are JSON { type, data: { text, value, ... } } (sendParameter
   in the SDK). Types used by TPN OS: 1 init, 2 status, 3 line feed,
   4 feed n, 5 cut, 6 align, 7 text size, 8 typeface, 9 style,
   10 line spacing, 12/13 text, 14 columns, 20/21 QR size/level,
   23/24 QR, 26/27 the picture just uploaded, 100 cash drawer. */
const STATUS_CODE = { ready: 0, cover: 3, paper: 7 };
let job = [], fmt = { align: 0, size: 24, style: 0 }, qrSize = 4, lastUpload = null;
function addOp(op) { job.push(op); }
function cut(kind) {
  if (!job.length) return;
  const ops = job; job = [];
  setTimeout(() => emit('slip', { printer: 'counter', ops, note: 'counter printer · ' + (ops.find((o) => o.t === 'text')?.s || (ops.some((o) => o.t === 'img') ? 'picture slip' : 'slip')).slice(0, 40) }), sim.slow);
}
function handlePrinterMessage(msg, sendJSON) {
  const d = msg.data || {}, type = msg.type;
  if (type === 0 && d.text === 'ping') return;
  if (sim.printer !== 'ready' && type !== 1 && type !== 2) { emit('fault', { note: `printer ${sim.printer}: dropped type ${type}` }); return; }
  switch (type) {
    case 1: break;                                                         // initPrinter(USB|SPI)
    case 2: sendJSON({ type: 2, data: { text: d.text, value: STATUS_CODE[sim.printer] ?? -1 } }); break;
    case 3: addOp({ t: 'feed', n: 1 }); break;
    case 4: addOp({ t: 'feed', n: Math.max(1, Math.round((d.value || 0) / 24)) }); break;
    case 5: cut('partial'); break;
    case 6: fmt.align = d.value; break;
    case 7: fmt.size = d.value; break;
    case 9: fmt.style = d.value; break;
    case 8: case 10: case 21: break;
    case 12: case 13: addOp({ t: 'text', s: String(d.text || '').replace(/\n$/, ''), align: type === 13 ? d.value : fmt.align, size: fmt.size, bold: fmt.style === 1 || fmt.style === 3 }); break;
    case 14: addOp({ t: 'cols', cols: d.colTextArr || [], widths: d.colWidthArr || [], aligns: d.colAlign || [], size: Array.isArray(d.size) ? d.size[0] : fmt.size, bold: fmt.style === 1 }); break;
    case 20: qrSize = d.value || 4; break;
    case 23: case 24: addOp({ t: 'qr', s: d.text, size: qrSize, align: type === 24 ? d.value : fmt.align }); break;
    case 26: case 27: addOp({ t: 'img', src: lastUpload, align: type === 27 ? d.value : 1 }); break;
    case 100: emit('drawer', { note: 'cash drawer opened' }); break;
    default: emit('fault', { note: 'unknown printer command type ' + type });
  }
}
function wsAccept(req, socket, onMessage) {
  const key = req.headers['sec-websocket-key'];
  const accept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(['HTTP/1.1 101 Switching Protocols', 'Upgrade: websocket', 'Connection: Upgrade', 'Sec-WebSocket-Accept: ' + accept, '', ''].join('\r\n'));
  const send = (str) => {
    const p = Buffer.from(str); let head;
    if (p.length < 126) head = Buffer.from([0x81, p.length]);
    else if (p.length < 65536) { head = Buffer.alloc(4); head[0] = 0x81; head[1] = 126; head.writeUInt16BE(p.length, 2); }
    else { head = Buffer.alloc(10); head[0] = 0x81; head[1] = 127; head.writeBigUInt64BE(BigInt(p.length), 2); }
    try { socket.write(Buffer.concat([head, p])); } catch (e) {}
  };
  let buf = Buffer.alloc(0), frag = '';
  socket.on('data', (c) => {
    buf = Buffer.concat([buf, c]);
    for (;;) {
      if (buf.length < 2) return;
      const fin = buf[0] & 0x80, op = buf[0] & 0x0f, masked = buf[1] & 0x80;
      let len = buf[1] & 0x7f, off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      const mask = masked ? buf.subarray(off, off + 4) : null; if (masked) off += 4;
      if (buf.length < off + len) return;
      const data = Buffer.from(buf.subarray(off, off + len)); buf = buf.subarray(off + len);
      if (mask) for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
      if (op === 8) { try { socket.end(Buffer.from([0x88, 0])); } catch (e) {} return; }
      if (op === 9) { try { socket.write(Buffer.concat([Buffer.from([0x8A, data.length]), data])); } catch (e) {} continue; }
      if (op === 1 || op === 0) { frag += data.toString(); if (fin) { const m = frag; frag = ''; onMessage(m, send); } }
    }
  });
  socket.on('error', () => {});
  return send;
}
const printerSockets = new Set();
const printerServer = http.createServer(async (req, res) => {
  cors(req, res);
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  if (sim.printer === 'off') { res.writeHead(503); return res.end(); }
  if (req.method === 'POST' && req.url.startsWith('/upload')) {
    // multipart/form-data with one "file" part: keep the picture for the next type 26/27.
    const body = await readBody(req).catch(() => null);
    const ct = req.headers['content-type'] || '';
    const b = (ct.match(/boundary=(.+)$/) || [])[1];
    if (body && b) {
      const start = body.indexOf('\r\n\r\n') + 4, end = body.lastIndexOf(Buffer.from('\r\n--' + b));
      const head = body.subarray(0, start).toString();
      const mime = (head.match(/Content-Type:\s*([^\r\n]+)/i) || [])[1] || 'image/png';
      lastUpload = `data:${mime};base64,${body.subarray(start, end).toString('base64')}`;
      res.writeHead(200, { 'content-type': 'text/plain' }); return res.end('ok');
    }
    res.writeHead(400); return res.end('');
  }
  res.writeHead(200, { 'content-type': 'text/plain' }); res.end('TPN iMin simulator · print service');
});
printerServer.on('upgrade', (req, socket) => {
  if (sim.printer === 'off' || !req.url.startsWith('/websocket')) { socket.destroy(); return; }
  printerSockets.add(socket);
  socket.on('close', () => printerSockets.delete(socket));
  wsAccept(req, socket, (text, send) => {
    let msg; try { msg = JSON.parse(text); } catch (e) { return; }
    handlePrinterMessage(msg, (o) => send(JSON.stringify(o)));
  });
  emit('connect', { note: 'page connected to the print service' });
});

/* ── 8091: the TPN Counter app's loopback link ─────────────── */
let rearState = null;
const isLan = (h) => { const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h || ''); if (!m) return false; const n = m.slice(1).map(Number); if (n.some((v) => v > 255)) return false; return n[0] === 10 || (n[0] === 172 && n[1] >= 16 && n[1] <= 31) || (n[0] === 192 && n[1] === 168); };
const relayServer = http.createServer(async (req, res) => {
  const ours = cors(req, res);
  const json = (code, o) => { res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(o ? JSON.stringify(o) : ''); };
  if (sim.relay === 'off') { req.socket.destroy(); return; }
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  const u = new URL(req.url, 'http://x');
  if (req.method === 'GET' && u.pathname === '/ping') return json(200, { ok: true, print: true, screen: true });
  if (!ours) return json(403);
  if (req.method === 'POST' && u.pathname === '/state') {
    const body = (await readBody(req, 64 * 1024).catch(() => Buffer.alloc(0))).toString();
    try { rearState = JSON.parse(body); emit('state', { state: rearState, note: 'rear screen: ' + rearState.mode }); } catch (e) {}
    return json(204);
  }
  if (req.method === 'POST' && u.pathname === '/print') {
    const host = u.searchParams.get('host'), port = Number(u.searchParams.get('port') || 9100);
    if (!isLan(host)) return json(502, { ok: false, error: 'not a printer on this network' });
    if (!(port >= 9100 && port <= 9109)) return json(502, { ok: false, error: 'bad port' });
    const body = await readBody(req, 2 * 1024 * 1024).catch(() => null);
    if (!body) return json(502, { ok: false, error: 'incomplete' });
    if (sim.kitchen !== 'ready') { emit('fault', { note: `kitchen printer ${host}:${port} is off` }); return json(502, { ok: false, error: 'could not reach the printer' }); }
    const out = escposToPng(body);
    setTimeout(() => emit('slip', { printer: 'kitchen', host, port, png: out.png ? 'data:image/png;base64,' + out.png.toString('base64') : null, dots: out.dots, text: out.text, note: `kitchen printer ${host} · ${out.dots}×${out.height} dots` }), sim.slow);
    return json(200, { ok: true });
  }
  json(404);
});

/* ── 7071: a working copy of the site (with --local) ─────────── */
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.mp3': 'audio/mpeg', '.txt': 'text/plain' };
const siteServer = http.createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (p.endsWith('/')) p += 'index.html';
  let file = path.join(LOCAL_DIR, path.normalize(p).replace(/^(\.\.[/\\])+/, ''));
  if (!file.startsWith(LOCAL_DIR)) { res.writeHead(403); return res.end(); }
  if (!path.extname(file) && fs.existsSync(file + '.html')) file += '.html';   // extensionless, like GitHub Pages
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404, { 'content-type': 'text/plain' }); return res.end('Not found: ' + p); }
    res.writeHead(200, { 'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(data);
  });
});

/* ── 7070: the dashboard ────────────────────────────────────── */
const dashboard = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/events') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
    res.write(`data: ${JSON.stringify({ type: 'hello', sim, history })}\n\n`);
    clients.add(res); req.on('close', () => clients.delete(res)); return;
  }
  if (u.pathname === '/set' && req.method === 'POST') {
    const body = JSON.parse((await readBody(req, 4096)).toString() || '{}');
    for (const k of ['printer', 'relay', 'kitchen', 'slow']) if (k in body) sim[k] = body[k];
    if (sim.printer === 'off') for (const s of printerSockets) { try { s.destroy(); } catch (e) {} }
    emit('settings', { sim, note: 'hardware: ' + JSON.stringify(sim) });
    res.writeHead(204); return res.end();
  }
  if (u.pathname === '/open' && req.method === 'POST') { const w = (await readBody(req, 64)).toString(); openWindows(w); res.writeHead(204); return res.end(); }
  if (u.pathname === '/qrcode.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return fs.createReadStream(path.join(ROOT, 'vendor', 'qrcode-generator-1.4.4.js')).on('error', () => res.end()).pipe(res); }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  res.end(fs.readFileSync(path.join(__dirname, 'dashboard.html'), 'utf8').replaceAll('%%SITE%%', SITE));
});

/* ── Browser windows ────────────────────────────────────────── */
function findBrowser(want) {
  const p = opt('browser-path', ''); if (p) return { kind: /firefox/i.test(p) ? 'firefox' : 'chrome', bin: p };
  const pf = [process.env.PROGRAMFILES, process.env['PROGRAMFILES(X86)'], process.env.LOCALAPPDATA].filter(Boolean);
  const cands = {
    chrome: process.platform === 'win32' ? pf.map((d) => path.join(d, 'Google', 'Chrome', 'Application', 'chrome.exe'))
      : process.platform === 'darwin' ? ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'] : ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser'],
    edge: process.platform === 'win32' ? pf.map((d) => path.join(d, 'Microsoft', 'Edge', 'Application', 'msedge.exe'))
      : process.platform === 'darwin' ? ['/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'] : ['microsoft-edge'],
    firefox: process.platform === 'win32' ? pf.map((d) => path.join(d, 'Mozilla Firefox', 'firefox.exe'))
      : process.platform === 'darwin' ? ['/Applications/Firefox.app/Contents/MacOS/firefox'] : ['firefox'],
  };
  const order = want === 'firefox' ? ['firefox'] : want === 'edge' ? ['edge'] : ['chrome', 'edge'];
  for (const k of order) for (const c of cands[k]) {
    if (path.isAbsolute(c) ? fs.existsSync(c) : (() => { try { execFileSync(process.platform === 'win32' ? 'where' : 'which', [c], { stdio: 'ignore' }); return true; } catch (e) { return false; } })())
      return { kind: k === 'firefox' ? 'firefox' : 'chrome', bin: c };
  }
  return null;
}
function chromeWindow(b, profile, url, w, h, x, y, ua, dpr) {
  const args = [`--user-data-dir=${profile}`, `--app=${url}`, `--window-size=${w},${h}`, `--window-position=${x},${y}`,
    `--user-agent=${ua}`, '--no-first-run', '--no-default-browser-check', '--disable-features=Translate'];
  if (dpr && dpr !== 1) args.push(`--force-device-scale-factor=${dpr}`);
  spawn(b.bin, args, { detached: true, stdio: 'ignore' }).unref();
}
function firefoxProfile(dir, ua) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'user.js'), [
    `user_pref("general.useragent.override", ${JSON.stringify(ua)});`,
    'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("browser.startup.homepage_override.mstone", "ignore");',
    'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
    'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);',
  ].join('\n'));
}
let browser = null;
function openWindows(which = 'all') {
  if (!browser) { console.log('No browser to open. Open the URLs in the dashboard yourself.'); return; }
  const counterProfile = path.join(PROFILE_DIR, browser.kind, 'counter');
  const kitchenProfile = path.join(PROFILE_DIR, browser.kind, 'kitchen');
  const counterUrl = SITE + 'tpn-dine-in-floor', rearUrl = SITE + 'tpn-dine-in-floor-customer', kitchenUrl = SITE + 'tpn-kitchen-station';
  const cw = Math.round(SCREEN.w / SCREEN.dpr), ch = Math.round(SCREEN.h / SCREEN.dpr);
  if (browser.kind === 'firefox') {
    firefoxProfile(counterProfile, UA('TPNCounter'));
    if (which === 'all' || which === 'counter') spawn(browser.bin, ['-profile', counterProfile, '-new-window', counterUrl, '-width', String(cw), '-height', String(ch)], { detached: true, stdio: 'ignore' }).unref();
    if ((which === 'all' && !flag('no-rear')) || which === 'rear') setTimeout(() => spawn(browser.bin, ['-profile', counterProfile, '-new-window', rearUrl], { detached: true, stdio: 'ignore' }).unref(), 2500);
    if ((which === 'all' && flag('kitchen')) || which === 'kitchen') { firefoxProfile(kitchenProfile, UA('TPNKitchen')); spawn(browser.bin, ['-profile', kitchenProfile, '-no-remote', '-new-window', kitchenUrl], { detached: true, stdio: 'ignore' }).unref(); }
    return;
  }
  // One profile for the counter and the rear screen: they share storage and
  // BroadcastChannel, which is how the rear screen hears the counter.
  if (which === 'all' || which === 'counter') chromeWindow(browser, counterProfile, counterUrl, cw, ch, 0, 0, UA('TPNCounter'), SCREEN.dpr);
  if ((which === 'all' && !flag('no-rear')) || which === 'rear') setTimeout(() => chromeWindow(browser, counterProfile, rearUrl, REAR.w, REAR.h, Math.min(cw, 1400), 40, UA('TPNCounter'), 1), 1500);
  if ((which === 'all' && flag('kitchen')) || which === 'kitchen') chromeWindow(browser, kitchenProfile, kitchenUrl, 1280, 800, 60, 60, UA('TPNKitchen'), 1);
}

/* ── Start ──────────────────────────────────────────────────── */
function listen(server, port, name) {
  return new Promise((ok) => {
    server.once('error', (e) => {
      console.error(`Port ${port} (${name}) is busy: ${e.code}. Close whatever uses it (the real TPN Counter app, another simulator) and try again.`);
      process.exit(1);
    });
    server.listen(port, '127.0.0.1', ok);
  });
}
(async () => {
  if (flag('fresh')) fs.rmSync(PROFILE_DIR, { recursive: true, force: true });
  await listen(printerServer, 8081, 'iMin print service');
  await listen(relayServer, 8091, 'TPN Counter app link');
  await listen(dashboard, 7070, 'dashboard');
  if (LOCAL) await listen(siteServer, 7071, 'local site');
  const want = opt('browser', 'chrome');
  browser = want === 'none' ? null : findBrowser(want);
  console.log(`
  TPN iMin simulator
  ─────────────────────────────────────────────
  Site            ${SITE}${LOCAL ? '   (serving ' + LOCAL_DIR + ')' : ''}
  Dashboard       http://127.0.0.1:7070/
  Print service   127.0.0.1:8081   (iMinprinterplugin)
  App link        127.0.0.1:8091   (TPN Counter ${VERSION}: rear screen + kitchen printer)
  Counter window  ${SCREEN.w}×${SCREEN.h}${SCREEN.dpr !== 1 ? ' at density ' + SCREEN.dpr : ''} · rear screen ${REAR.w}×${REAR.h}
  Browser         ${browser ? browser.kind + ' (' + browser.bin + ')' : 'none — open the dashboard and use its links'}
  Profile         ${PROFILE_DIR}   (your sign-in stays between runs; --fresh clears it)

  Kitchen printer: in the counter's printer menu use any address on a home
  network, e.g. 192.168.1.250, port 9100. Its tickets appear on the dashboard.
  Ctrl+C to stop.
`);
  emit('settings', { sim, note: 'simulator started' });
  openDashboard();
  if (browser) setTimeout(() => openWindows('all'), 600);
})();
function openDashboard() {
  const url = 'http://127.0.0.1:7070/';
  const cmd = process.platform === 'win32' ? ['cmd', ['/c', 'start', '', url]] : process.platform === 'darwin' ? ['open', [url]] : ['xdg-open', [url]];
  try { spawn(cmd[0], cmd[1], { detached: true, stdio: 'ignore' }).unref(); } catch (e) {}
}
process.on('SIGINT', () => { console.log('\nStopped.'); process.exit(0); });
