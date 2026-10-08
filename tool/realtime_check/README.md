# Realtime check (WebSocket / Socket.IO / SSE)

Checks ProxyPin's reverse proxy with real-time traffic: Socket.IO (long-polling, WebSocket, upgrade,
acks, binary, rooms, namespaces, server push, disconnect/reconnect), raw WebSocket (subprotocols, large
and fragmented messages, ping/pong, close codes, abrupt drops, permessage-deflate, 50 concurrent
connections) and server-sent events.

1. Start the test backend on the host (Node 18+):

   ```bash
   cd tool/realtime_check && npm install && node server.mjs
   ```

   Optional, for a `wss://` upstream on port 18443, create a self-signed certificate first:

   ```bash
   openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 30 -subj "/CN=localhost"
   ```

2. Add reverse proxy rules in ProxyPin (Settings → Reverse Proxy). From a container, the host is
   `host.docker.internal`:
   - `/sio` → `http://host.docker.internal:18093`
   - `/sios` → `https://host.docker.internal:18443` (if you created the certificate)

3. Run the checks through ProxyPin (base URL, rule path, label). `NODE_TLS_REJECT_UNAUTHORIZED=0` is only
   needed for an `https://` base URL whose CA Node doesn't know, such as OrbStack's `*.orb.local`:

   ```bash
   NODE_TLS_REJECT_UNAUTHORIZED=0 node client_test.mjs https://proxypin.proxypin.orb.local /sio orb
   ```

   Each check prints PASS or FAIL; the run takes about 35 s because one Socket.IO session stays on
   long-polling for 30 s.

4. Browser check: open `<base URL>/sio/`. The page uses the Socket.IO browser client, a raw WebSocket
   and an EventSource through the proxy and prints the results. The captured traffic, including every
   Socket.IO frame, shows up in the ProxyPin UI.
