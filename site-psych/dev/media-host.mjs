/**
 * media-host — П4c c3: Range-статика с проверкой подписи (dev-двойник прод-nginx
 * secure-link). Байты видео НЕ ходят через Haskell-сервер: cxm-server-pg только
 * ПОДПИСЫВАЕТ URL (Agdelte.Auth.SignedUrl: url?expires=TS&sig=hex-HMAC-SHA256(secret,
 * url|expires)), а хост проверяет подпись/срок и отдаёт файл (206 c Content-Range —
 * перемотка). Upload: PUT /media-store/<id>/up по подписанному uploadUrl из /v1/media
 * (отдельная подписанная база — GET-подпись не годится для записи и наоборот).
 * Файлы: <dir>/<id> + сайдкар <id>.mime (content-type для отдачи).
 */
import { createHmac, timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';
import { promises as fs, createReadStream } from 'node:fs';
import { join } from 'node:path';

const nowSec = () => Math.floor(Date.now() / 1000);

function sigOk(secret, base, expires, sig) {
  if (!/^\d+$/.test(expires) || !/^[0-9a-f]+$/i.test(sig || '')) return false;
  if (Number(expires) < nowSec()) return false;
  const want = createHmac('sha256', secret).update(`${base}|${expires}`).digest('hex');
  const a = Buffer.from(want, 'utf8'); const b = Buffer.from(sig.toLowerCase(), 'utf8');
  return a.length === b.length && timingSafeEqual(a, b);
}

export function mediaHandler({ secret, dir, maxBytes = 200 * 1024 * 1024 }) {
  return async (req, res) => {
    const u = new URL(req.url, 'http://x');
    const mPut = u.pathname.match(/^\/media-store\/(\d+)\/up$/);
    const mGet = u.pathname.match(/^\/media-store\/(\d+)$/);
    if (!mPut && !mGet) return false;

    const base = u.pathname;                      // подписанная база = сам путь
    const ok = sigOk(secret, base, u.searchParams.get('expires'), u.searchParams.get('sig'));
    if (!ok) { res.writeHead(403); res.end('bad or expired signature'); return true; }

    if (mPut && req.method === 'PUT') {
      await fs.mkdir(dir, { recursive: true });
      const chunks = []; let size = 0; let over = false;
      for await (const c of req) {
        size += c.length;
        if (size > maxBytes) { over = true; break; }
        chunks.push(c);
      }
      if (over) { res.writeHead(413); res.end('too large'); return true; }
      await fs.writeFile(join(dir, mPut[1]), Buffer.concat(chunks));
      await fs.writeFile(join(dir, mPut[1] + '.mime'),
        req.headers['content-type'] || 'application/octet-stream');
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"ok":true}');
      return true;
    }

    if (mGet && req.method === 'GET') {
      const file = join(dir, mGet[1]);
      let st;
      try { st = await fs.stat(file); } catch { res.writeHead(404); res.end(); return true; }
      const mime = await fs.readFile(file + '.mime', 'utf8').catch(() => 'application/octet-stream');
      const range = (req.headers.range || '').match(/^bytes=(\d*)-(\d*)$/);
      if (range && (range[1] !== '' || range[2] !== '')) {
        const from = range[1] === '' ? Math.max(0, st.size - Number(range[2])) : Number(range[1]);
        const to = range[1] !== '' && range[2] !== '' ? Math.min(Number(range[2]), st.size - 1)
                                                      : st.size - 1;
        if (from > to || from >= st.size) {
          res.writeHead(416, { 'content-range': `bytes */${st.size}` }); res.end(); return true;
        }
        res.writeHead(206, { 'content-type': mime, 'accept-ranges': 'bytes',
          'content-length': to - from + 1,
          'content-range': `bytes ${from}-${to}/${st.size}` });
        createReadStream(file, { start: from, end: to }).pipe(res);
        return true;
      }
      res.writeHead(200, { 'content-type': mime, 'accept-ranges': 'bytes',
                           'content-length': st.size });
      createReadStream(file).pipe(res);
      return true;
    }

    res.writeHead(405); res.end(); return true;
  };
}

// standalone (смоук): свой порт, отдельный каталог
export function startMediaHost({ secret, dir, port, maxBytes }) {
  const handle = mediaHandler({ secret, dir, maxBytes });
  const srv = createServer(async (req, res) => {
    if (!(await handle(req, res))) { res.writeHead(404); res.end(); }
  });
  return new Promise((resolve) => srv.listen(port, '127.0.0.1', () => resolve(srv)));
}
