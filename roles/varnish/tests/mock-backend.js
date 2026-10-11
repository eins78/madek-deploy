// Mock of the Madek webapp's HTTP behaviour for the offline VCL tests (run-tests.sh).
// Every anonymous-looking answer: Cache-Control private, weak ETag, Vary: Accept, Set-Cookie
// _madek_session, a per-request "csrf" token in the body. The body echoes what the backend saw.
// Routes: /status, /always500, /r404, /r403, /r302, /nostore (private, no-store),
//         /smaxage (public, max-age=0, s-maxage=1); everything else 200.
// Control (POST, so Varnish passes it): POST /__mode?m=ok|500|close|sick|nostore   POST /__count?path=/x
const http = require('http');
let mode = 'ok';
const counts = {};
http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (req.method === 'POST' && u.pathname === '/__mode') { mode = u.searchParams.get('m'); return res.end(mode); }
  if (req.method === 'POST' && u.pathname === '/__count') { return res.end(String(counts[u.searchParams.get('path')] || 0)); }
  counts[u.pathname] = (counts[u.pathname] || 0) + 1;
  if (u.pathname === '/status') { res.statusCode = mode === 'sick' ? 500 : 200; return res.end('OK'); }
  if (mode === 'close') return req.socket.destroy();
  let status = 200;
  if (mode === '500' || mode === 'sick' || u.pathname === '/always500') status = 500;
  else if (u.pathname === '/r404') status = 404;
  else if (u.pathname === '/r403') status = 403;
  else if (u.pathname === '/r302') { status = 302; res.setHeader('Location', '/elsewhere'); }
  let cacheControl = 'max-age=0, private, must-revalidate';
  if (mode === 'nostore' || u.pathname === '/nostore') cacheControl = 'private, no-store';
  else if (u.pathname === '/smaxage') cacheControl = 'public, max-age=0, s-maxage=1, stale-while-revalidate=60';
  const csrf = Math.random().toString(36).slice(2);
  const json = /application\/json/.test(req.headers.accept || '');
  const body = JSON.stringify({ n: counts[u.pathname], url: req.url, cookie: req.headers.cookie || null,
    accept: req.headers.accept || null, xff: req.headers['x-forwarded-for'] || null, csrf });
  res.statusCode = status;
  res.setHeader('Content-Type', json ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', cacheControl);
  res.setHeader('ETag', 'W/"' + csrf + '"');
  res.setHeader('Vary', 'Accept');
  res.setHeader('Set-Cookie', '_madek_session=' + csrf + '; path=/; HttpOnly; SameSite=Lax');
  res.setHeader('X-Backend-N', String(counts[u.pathname]));
  res.end(body);
}).listen(3000);
