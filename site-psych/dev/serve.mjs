#!/usr/bin/env node
// site-psych dev server: статика (dev/ + _build/ + agdelte runtime) + same-origin прокси
// прочих путей на живой cxm-server-pg (:8138). Порт 8136 (cxm-ui-харнесс живёт на 8137).
//   node dev/serve.mjs   →   http://127.0.0.1:8136/dev/
import { createServer, request as httpRequest } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, resolve, dirname, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mediaHandler } from './media-host.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const AGDELTE = process.env.AGDELTE || resolve(process.env.HOME, '.agda/agdelte');
const API = new URL(process.env.CXM_API || 'http://127.0.0.1:8138');
const PORT = Number(process.env.PORT || 8136);
// П4c: медиа-байты (подписанные URL от cxm-server; прод-аналог — nginx secure-link)
const media = mediaHandler({
  secret: process.env.CXM_MEDIA_SECRET || 'dev-media-secret',
  dir: process.env.CXM_MEDIA_DIR || '/tmp/cxm-media',
});

const MOUNTS = [
  ['/dev/', join(ROOT, 'dev')],
  ['/_build/', join(ROOT, '_build')],
  ['/runtime/', join(AGDELTE, 'runtime')],
];
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript',
  '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json' };

createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (path === '/' || path === '/dev') { res.writeHead(302, { location: '/dev/' }); return res.end(); }
  if (await media(req, res)) return;

  const mount = MOUNTS.find(([p]) => path.startsWith(p));
  if (mount) {
    const rel = path.slice(mount[0].length) || 'index.html';
    const file = normalize(join(mount[1], rel));
    if (!file.startsWith(mount[1])) { res.writeHead(403); return res.end(); }
    try {
      const body = await readFile(file);
      res.writeHead(200, { 'content-type': MIME[extname(file)] || 'application/octet-stream',
                           'cache-control': 'no-store' });
      return res.end(body);
    } catch { res.writeHead(404); return res.end('not found: ' + path); }
  }

  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const up = httpRequest(
      { host: API.hostname, port: API.port, method: req.method, path,
        headers: { ...req.headers, host: API.host } },
      (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
    up.on('error', (e) => { res.writeHead(502); res.end('proxy: ' + e.message); });
    up.end(Buffer.concat(chunks));
  });
}).listen(PORT, '127.0.0.1', () => {
  console.log(`site-psych dev: http://127.0.0.1:${PORT}/dev/  (API → ${API.origin})`);
});
