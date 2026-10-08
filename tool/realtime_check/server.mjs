// Socket.IO + raw WebSocket + SSE test backend for checking the reverse proxy (see README.md).
// Serves http on 18093 and, when key.pem/cert.pem exist next to this file, https on 18443.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import { Server } from 'socket.io';
import { WebSocketServer } from 'ws';

const dir = new URL('.', import.meta.url).pathname;
const stats = { disconnects: {}, rawCloses: {}, pongs: {} };
const page = fs.readFileSync(dir + 'page.html');

function handler(req, res) {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/' || url.pathname === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(page);
  }
  if (url.pathname === '/stats') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(stats));
  }
  if (url.pathname === '/sse') { // server-sent events, then the server closes the connection
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'close' });
    let n = 0;
    const t = setInterval(() => {
      res.write(`data: tick ${++n}\n\n`);
      if (n === 3) { clearInterval(t); url.searchParams.has('abort') ? res.socket.end() : res.end(); }
    }, 200);
    return;
  }
  res.writeHead(404); res.end('not found');
}

function setupSocketIo(server, label) {
  const io = new Server(server, { maxHttpBufferSize: 10e6, destroyUpgrade: false, cors: { origin: true, credentials: true } });
  io.on('connection', (socket) => {
    const tag = socket.handshake.query.tag || socket.id;
    socket.emit('welcome', { id: socket.id, transport: socket.conn.transport.name, upstream: label });
    socket.on('echo', (data, ack) => ack?.({ echo: data, transport: socket.conn.transport.name }));
    socket.on('binary', (buf, ack) => ack?.(buf));
    socket.on('broadcast', (msg) => socket.broadcast.emit('broadcast', msg));
    socket.on('join', (room, ack) => { socket.join(room); ack?.('joined ' + room); });
    socket.on('room', ({ room, msg }) => io.to(room).emit('room', msg));
    socket.on('kick', () => socket.disconnect(true));
    socket.on('terminate-me', () => {
      const t = socket.conn.transport;
      if (t.name === 'websocket') t.socket.terminate(); else socket.conn.close();
    });
    socket.on('disconnect', (reason) => { stats.disconnects[tag] = { at: Date.now(), reason }; });
  });
  io.of('/admin').on('connection', (socket) => {
    socket.emit('admin-welcome', 'hello admin');
    socket.on('echo', (data, ack) => ack?.({ admin: data }));
  });
  setInterval(() => io.to('tick').emit('tick', Date.now()), 1000);
  return io;
}

function setupRaw(server) {
  const plain = new WebSocketServer({ noServer: true, handleProtocols: (p) => (p.has('chat.v2') ? 'chat.v2' : false) });
  const deflate = new WebSocketServer({ noServer: true, perMessageDeflate: { threshold: 0 } });
  for (const wss of [plain, deflate]) {
    wss.on('connection', (ws, req) => {
      const tag = new URL(req.url, 'http://x').searchParams.get('tag') || 'anon';
      ws.on('pong', () => { stats.pongs[tag] = (stats.pongs[tag] || 0) + 1; });
      ws.on('close', (code) => { stats.rawCloses[tag] = { at: Date.now(), code }; });
      ws.on('message', (data, isBinary) => {
        if (isBinary) return ws.send(data, { binary: true });
        const text = data.toString();
        if (text.startsWith('cmd:big:')) return ws.send(Buffer.alloc(Number(text.slice(8)), 7), { binary: true });
        if (text === 'cmd:frag') {
          ws.send('part1-', { fin: false });
          ws.send('part2-', { fin: false });
          return ws.send('part3', { fin: true });
        }
        if (text.startsWith('cmd:close:')) return ws.close(Number(text.slice(10)), 'bye');
        if (text === 'cmd:ping') return ws.ping('hi');
        if (text === 'cmd:terminate') return ws.terminate();
        ws.send('echo:' + text);
      });
    });
  }
  server.on('upgrade', (req, socket, head) => {
    const path = new URL(req.url, 'http://x').pathname;
    const wss = path === '/raw' ? plain : path === '/rawz' ? deflate : null;
    if (wss) wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  });
}

const plainServer = http.createServer(handler);
setupSocketIo(plainServer, 'http');
setupRaw(plainServer);
plainServer.listen(18093, '127.0.0.1', () => console.log('http on 127.0.0.1:18093'));

if (fs.existsSync(dir + 'key.pem') && fs.existsSync(dir + 'cert.pem')) {
  const tlsServer = https.createServer({ key: fs.readFileSync(dir + 'key.pem'), cert: fs.readFileSync(dir + 'cert.pem') }, handler);
  setupSocketIo(tlsServer, 'https');
  setupRaw(tlsServer);
  tlsServer.listen(18443, '127.0.0.1', () => console.log('https on 127.0.0.1:18443'));
} else {
  console.log('no key.pem/cert.pem: https (wss) upstream disabled');
}
