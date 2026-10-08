// Socket.IO + raw WebSocket checks through the ProxyPin reverse proxy.
//   node client_test.mjs <base, e.g. http://localhost:8082> <rule prefix, e.g. /sio> <label>
import crypto from 'node:crypto';
import { io } from 'socket.io-client';
import WebSocket from 'ws';

const [base, prefix, label] = process.argv.slice(2);
const tls = { rejectUnauthorized: false }; // OrbStack's local CA is not in Node's store
const sioPath = prefix + '/socket.io';
const wsBase = base.replace(/^http/, 'ws') + prefix;
const run = `${label}-${Date.now()}`;
let failures = 0;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const check = (name, ok, detail = '') => {
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'} [${label}] ${name}${detail ? ` (${detail})` : ''}`);
};
const withTimeout = (p, ms, what) =>
  Promise.race([p, new Promise((_, j) => setTimeout(() => j(new Error(`timeout: ${what}`)), ms))]);
const once = (emitter, ev, ms = 8000) => withTimeout(new Promise((r) => emitter.once(ev, (...a) => r(a))), ms, ev);
const emitAck = (s, ev, data, ms = 8000) => withTimeout(new Promise((r) => s.emit(ev, data, r)), ms, ev);
const waitFor = async (cond, ms) => {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) if (cond()) return true;
  return cond();
};
const stats = async () => (await fetch(`${base}${prefix}/stats`)).json();
const attempt = async (name, fn) => {
  try {
    await fn();
  } catch (e) {
    check(name, false, String(e.message || e));
  }
};

function open(opts = {}, nsp = '') {
  const s = io(base + nsp, { path: sioPath, reconnection: false, forceNew: true, ...tls, ...opts });
  const welcome = once(s, nsp ? 'admin-welcome' : 'welcome');
  welcome.catch(() => {}); // only some tests wait for it
  const connected = new Promise((resolve, reject) => {
    s.once('connect', () => resolve(s));
    s.once('connect_error', (e) => reject(e));
  });
  return { s, welcome, connected: withTimeout(connected, 8000, 'connect') };
}

const rawOpen = (path, protocols) =>
  new Promise((resolve, reject) => {
    const ws = new WebSocket(wsBase + path, protocols, tls);
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
const nextMessage = (ws, ms = 8000) =>
  withTimeout(new Promise((r) => ws.once('message', (data, isBinary) => r({ data, isBinary }))), ms, 'message');
const closed = (ws, ms = 8000) =>
  withTimeout(new Promise((r) => ws.once('close', (code, reason) => r({ code, reason: reason.toString() }))), ms, 'close');

// ------------------------------------------------------------------------------------- Socket.IO
async function pollingOnlyLongSession() {
  const tag = `${run}-poll`;
  const P = open({ transports: ['polling'], query: { tag } });
  await P.connected;
  const e1 = await emitAck(P.s, 'echo', 'poll-1');
  check('socket.io polling-only: emit + ack', e1.echo === 'poll-1' && e1.transport === 'polling', e1.transport);
  const blob = crypto.randomBytes(64 * 1024);
  const back = await emitAck(P.s, 'binary', blob);
  check('socket.io polling-only: 64 KB binary', Buffer.compare(Buffer.from(back), blob) === 0);
  await sleep(30000); // longer than one long-poll cycle (server pingInterval 25 s)
  check('socket.io polling-only: still connected after 30 s of long-polling', P.s.connected);
  const e2 = await emitAck(P.s, 'echo', 'poll-2');
  check('socket.io polling-only: ack after 30 s', e2.echo === 'poll-2');
  P.s.close();
}

async function socketIo() {
  const A = open({ query: { tag: `${run}-A` } });
  await A.connected;
  const [w] = await A.welcome;
  check('socket.io connect (default transports)', true, `handshake via ${w.transport}, upstream ${w.upstream}`);
  const upgraded = await waitFor(() => A.s.io.engine.transport.name === 'websocket', 8000);
  check('socket.io upgrades polling -> websocket', upgraded, A.s.io.engine.transport.name);
  const r = await emitAck(A.s, 'echo', 'ping-1');
  check('socket.io emit + ack after upgrade', r.echo === 'ping-1' && r.transport === 'websocket', r.transport);

  const small = crypto.randomBytes(1024);
  check('socket.io binary 1 KB', Buffer.compare(Buffer.from(await emitAck(A.s, 'binary', small)), small) === 0);
  const big = crypto.randomBytes(2 * 1024 * 1024);
  const t0 = Date.now();
  const bigBack = await emitAck(A.s, 'binary', big, 30000);
  check('socket.io binary 2 MB', Buffer.compare(Buffer.from(bigBack), big) === 0, `${Date.now() - t0} ms`);

  const B = open({ query: { tag: `${run}-B` } });
  await B.connected;
  const gotBroadcast = once(B.s, 'broadcast');
  A.s.emit('broadcast', 'hello-B');
  check('socket.io broadcast to another client', (await gotBroadcast)[0] === 'hello-B');

  await emitAck(B.s, 'join', 'r1');
  let aGotRoom = false;
  A.s.on('room', () => (aGotRoom = true));
  const roomMsg = once(B.s, 'room');
  A.s.emit('room', { room: 'r1', msg: 'to-r1' });
  const [rm] = await roomMsg;
  await sleep(300);
  check('socket.io rooms (only members receive)', rm === 'to-r1' && !aGotRoom);

  const N = open({}, '/admin');
  await N.connected;
  const [aw] = await N.welcome;
  const na = await emitAck(N.s, 'echo', 'x');
  check('socket.io namespace /admin', aw === 'hello admin' && na.admin === 'x');

  await emitAck(A.s, 'join', 'tick');
  let ticks = 0;
  A.s.on('tick', () => ticks++);
  await sleep(3300);
  check('socket.io server push (1 tick/s)', ticks >= 3, `${ticks} ticks in 3.3 s`);

  const W = open({ transports: ['websocket'], query: { tag: `${run}-W` } });
  await W.connected;
  const we = await emitAck(W.s, 'echo', 'ws-only');
  check('socket.io websocket-only: emit + ack', we.transport === 'websocket');
  const kicked = once(W.s, 'disconnect');
  W.s.emit('kick');
  check('socket.io server-initiated disconnect', (await kicked)[0] === 'io server disconnect');

  // upstream drops the TCP connection without a close frame -> the client must notice right away
  const X = open({ transports: ['websocket'], reconnection: true, reconnectionDelay: 200, reconnectionDelayMax: 500, query: { tag: `${run}-X` } });
  await X.connected;
  const t1 = Date.now();
  const lost = once(X.s, 'disconnect', 60000);
  X.s.emit('terminate-me');
  const [why] = await lost;
  const lostMs = Date.now() - t1;
  check('socket.io: upstream connection drop reaches client quickly', lostMs < 3000, `${why} after ${lostMs} ms`);
  const reconnected = await waitFor(() => X.s.connected, 8000);
  check('socket.io: client reconnects automatically', reconnected);
  X.s.close();

  // client drops the TCP connection -> the server must notice right away
  const yTag = `${run}-Y`;
  const Y = open({ transports: ['websocket'], query: { tag: yTag } });
  await Y.connected;
  const t2 = Date.now();
  Y.s.io.engine.transport.ws._socket.destroy();
  await waitFor(() => false, 2500);
  const d = (await stats()).disconnects[yTag];
  check('socket.io: client connection drop reaches server quickly', d && d.at - t2 < 2500,
      d ? `${d.reason} after ${d.at - t2} ms` : 'server still sees the client');

  for (const c of [A, B, N]) c.s.close();
}

// ----------------------------------------------------------------------------------- raw WebSocket
async function rawWebSocket() {
  const tag = `${run}-raw`;
  const ws = await rawOpen(`/raw?tag=${tag}`, ['chat.v1', 'chat.v2']);
  check('ws subprotocol negotiation', ws.protocol === 'chat.v2', ws.protocol);
  ws.send('hello');
  check('ws text echo', (await nextMessage(ws)).data.toString() === 'echo:hello');
  for (const size of [125, 126, 65535, 65536, 1024 * 1024]) {
    const blob = crypto.randomBytes(size);
    ws.send(blob);
    const m = await nextMessage(ws, 20000);
    check(`ws binary echo ${size} B`, m.isBinary && Buffer.compare(m.data, blob) === 0);
  }
  ws.send('cmd:big:5000000');
  const big = await nextMessage(ws, 30000);
  check('ws 5 MB server message', big.data.length === 5000000);
  ws.send('cmd:frag');
  check('ws fragmented message (3 frames)', (await nextMessage(ws)).data.toString() === 'part1-part2-part3');
  ws.send('cmd:ping');
  await sleep(500);
  check('ws server ping -> client pong', ((await stats()).pongs[tag] || 0) >= 1);
  const c = closed(ws);
  ws.send('cmd:close:4001');
  const cc = await c;
  check('ws close code + reason propagate', cc.code === 4001 && cc.reason === 'bye', `${cc.code} ${cc.reason}`);

  const t = await rawOpen(`/raw?tag=${tag}-t`);
  const t0 = Date.now();
  const tc = closed(t, 60000);
  t.send('cmd:terminate');
  const tcr = await tc;
  check('ws upstream drop (no close frame) reaches client quickly', Date.now() - t0 < 3000, `code ${tcr.code} after ${Date.now() - t0} ms`);

  const uTag = `${tag}-u`;
  const u = await rawOpen(`/raw?tag=${uTag}`);
  const t1 = Date.now();
  u.terminate();
  await sleep(2000);
  const uc = (await stats()).rawCloses[uTag];
  check('ws client drop reaches server quickly', uc && uc.at - t1 < 2000, uc ? `after ${uc.at - t1} ms` : 'server still open');

  const z = await rawOpen(`/rawz?tag=${tag}-z`);
  const text = 'compress me '.repeat(20000);
  z.send(text);
  const zm = await nextMessage(z);
  check('ws permessage-deflate', /permessage-deflate/.test(z.extensions) && zm.data.toString() === 'echo:' + text, z.extensions);
  z.close();

  const sockets = await Promise.all(Array.from({ length: 50 }, (_, i) => rawOpen(`/raw?tag=${tag}-c${i}`)));
  const ok = await Promise.all(
    sockets.map(async (s, i) => {
      for (let n = 0; n < 20; n++) {
        s.send(`m${i}-${n}`);
        if ((await nextMessage(s)).data.toString() !== `echo:m${i}-${n}`) return false;
      }
      s.close();
      return true;
    }),
  );
  check('ws 50 concurrent connections x 20 messages', ok.every(Boolean), `${ok.filter(Boolean).length}/50`);
}

async function sse() {
  const t0 = Date.now();
  const res = await fetch(`${base}${prefix}/sse`);
  let text = '';
  try {
    for await (const chunk of res.body) text += Buffer.from(chunk).toString();
  } catch (_) {
    // the upstream ends the stream by closing the connection
  }
  const events = (text.match(/data: tick/g) || []).length;
  check('SSE events stream and end when upstream closes', events === 3 && Date.now() - t0 < 5000, `${events} events, ${Date.now() - t0} ms`);
}

const poll = pollingOnlyLongSession().catch((e) => check('socket.io polling-only session', false, String(e.message || e)));
await attempt('socket.io suite', socketIo);
await attempt('raw websocket suite', rawWebSocket);
await attempt('SSE', () => withTimeout(sse(), 15000, 'sse'));
await poll;
console.log(`[${label}] ${failures === 0 ? 'ALL PASSED' : `${failures} FAILED`}`);
process.exit(failures === 0 ? 0 : 1);
