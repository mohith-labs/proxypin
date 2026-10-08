# ProxyPin Web (reverse proxy + browser UI)

ProxyPin can run as a server, for example in Docker, and be used from a browser. One port serves both:

| URL | What |
|---|---|
| `http://localhost:8080/__proxypin/` | the ProxyPin UI (the desktop UI, compiled for the web) |
| `http://localhost:8080/<anything else>` | **reverse proxy**: matched against your rules and forwarded to the rule's target |

Every request that goes through the reverse proxy is captured and runs through the normal ProxyPin
pipeline: you see it live in the UI, and breakpoints, request rewrite, request map, scripts, request block,
hosts, network throttling and request crypto all apply to it.

Example: a rule `/proxy → https://example.com` makes `http://localhost:8080/proxy/users?id=1` call
`https://example.com/users?id=1`. Point your app or curl at the left-hand URL. Both the request and the
response are captured and can be intercepted.

## Run with Docker

```bash
docker compose up -d --build        # or:
docker build -t proxypin-web .
docker run -d --name proxypin -p 8080:8080 -v proxypin-data:/data proxypin-web
```

Open `http://localhost:8080/__proxypin/`, then go to **Settings → Reverse Proxy** (or the route icon in the
toolbar) and add a rule.

- Data (rules, scripts, history, favorites, uploaded files, the generated CA) lives in the `/data` volume,
  so it survives restarts and upgrades.
- To require a login, set `PROXYPIN_PASSWORD` (and optionally `PROXYPIN_USER`, which defaults to `admin`).
  The login protects the UI and its API. The reverse-proxied paths stay open, because they are the service
  you are proxying.
- To expose ProxyPin only on this machine, use `-p 127.0.0.1:8080:8080`.
- The image runs as the non-root `node` user, uses `tini` as PID 1, and has a health check
  (`/__proxypin/api/session`).

## Reverse proxy rules

| Field | Meaning |
|---|---|
| Path | Prefix to match, for example `/api`. It matches `/api`, `/api/...` and `/api?...`, but not `/apis`. `/` matches everything. |
| Target | `http(s)://host[:port][/base-path]`. |
| Strip path prefix (default on) | `/api/users → <target>/users`. Turn it off to forward `/api/users → <target>/api/users`. |
| Preserve Host header (default off) | Off: the upstream sees `Host: <target host>`. On: it sees the client's `Host`. |
| Rewrite redirects and cookies (default on) | `Location`/`Content-Location` headers that point at the target are mapped back to the proxy path; `Set-Cookie` loses its `Domain` and gets the proxy path. |

- When several rules match, the longest path wins. A rule can be switched off individually, and all
  rules can be switched off with the page's main switch.
- If no rule matches, the server answers 404 with a short help page that lists the configured paths. These
  requests are not captured: browsers and extensions send plenty of them to the console's own origin.
  `GET /` redirects to the UI unless a rule covers `/`.
- `/__proxypin` is reserved. `CONNECT` is rejected (405): this port is a reverse proxy, not a forward proxy.
- Like desktop ProxyPin, upstream HTTPS certificates are **not verified**, so self-signed and internal
  targets work. An **External Proxy** set in the settings is used for upstream connections.
- The reverse proxy accepts plain HTTP from clients. Put a TLS-terminating proxy in front of it if
  clients need HTTPS. OrbStack's `https://<container>.orb.local` domains work out of the box; the
  request detail then shows the `https://` / `wss://` URL the client used (from `X-Forwarded-Proto`).

**Proxying websites in a browser:** pages often reference absolute paths, such as `<script src="/app.js">`,
that do not carry your rule's prefix. Those requests miss the rule and get the 404 help page (the browser's
network tab shows them). Add rules for those paths, or use a `/` catch-all rule for the site. APIs called
by apps don't have this problem.

## WebSocket, Socket.IO and SSE

- WebSocket upgrades are proxied to `ws://` and `wss://` targets. Frames (text, binary, fragmented,
  compressed) show up in the request's **WebSocket** tab. Close codes and disconnects reach the other
  side immediately.
- Socket.IO works with every transport: long-polling, WebSocket, and polling upgrading to WebSocket.
  Namespaces, rooms, acks and binary payloads all work. Behind a path prefix, tell the client where
  Socket.IO lives, because its default path `/socket.io` doesn't carry the prefix:

  ```js
  io('https://proxypin.proxypin.orb.local', { path: '/myapp/socket.io' }) // rule: /myapp -> http://backend:3000
  ```

  If you can't change the client, add a second rule `/socket.io → http://backend:3000` with
  **Strip path prefix** turned off.
- Server-sent events (`text/event-stream`) are streamed live, and each event is listed in the request.

## What works in the web UI

The web UI is the desktop UI. Windows that open as separate OS windows on desktop open as in-page windows
here (draggable, resizable).

| Feature | Notes |
|---|---|
| Live capture list, detail tabs, search/filters, domain list | Capture start/stop pauses recording on the server for every browser tab. |
| Breakpoints (request and response) | The editor opens in the browser. A paused request continues unmodified after `PROXYPIN_BREAKPOINT_TIMEOUT` seconds (600). |
| Request rewrite, request map (local/remote/script), request block, hosts, throttling, request crypto | Rules are stored on the server and apply immediately. Files you pick (for example a map-local body) are uploaded to `/data/files/`. |
| Scripts, script console, toolbox JS runner | Scripts run on the server in Node.js (same `onRequest`/`onResponse` API, `console`, `fetch`, `md5`, `File`). Logs stream to the browser. |
| Repeat, custom repeat, edit & send, compose | Sent from the server. The replay is captured like on desktop. |
| Favorites, history (save session, import/export HAR) | Stored in `/data`. Exports download as files. |
| Settings sync | Several tabs or users can work at the same time; a change made in one tab reloads in the others. |
| Compressed bodies (gzip, deflate, Brotli, zstd) | Shown decoded everywhere, including breakpoint editors. The browser can't decode Brotli and zstd reliably, so the server sends those decoded. |

Not available in the browser: system proxy, forward-proxy mode for devices, HTTPS interception of client
traffic (and so the SSL/certificate menu), Wi-Fi/QR device pairing, desktop app updates, and process icons.
The browser cannot open raw sockets, so connectivity checks (for example of an External Proxy) are run
from the server.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PORT` / `PROXYPIN_PORT` | `8080` | Listen port for the UI and the reverse proxy |
| `PROXYPIN_BIND` | `0.0.0.0` | Listen address |
| `PROXYPIN_DATA_DIR` | `/data` (image), `./data` (source) | Rules, scripts, history, favorites, uploaded files, CA |
| `PROXYPIN_USER` / `PROXYPIN_PASSWORD` | `admin` / unset | UI login. Auth is off while the password is unset or empty. |
| `PROXYPIN_HISTORY_LIMIT` | `2000` | Captured requests kept in memory for the UI |
| `PROXYPIN_BREAKPOINT_TIMEOUT` | `600` | Seconds a breakpoint may stay paused |
| `PROXYPIN_LOG_LEVEL` | `info` | `debug` for verbose logs |
| `PROXYPIN_LANG` | `$LANG` | Language of server-generated pages (`en`, `zh`) |
| `PROXYPIN_NODE`, `PROXYPIN_SCRIPT_WORKER` | set in the image | Node.js binary and script worker |
| `PROXYPIN_WEB_DIR`, `PROXYPIN_HOME` | set in the image | Compiled web UI and install root |
| `PROXYPIN_LIBZSTD` | system `libzstd` | Path to libzstd, if it is not found automatically (zstd bodies) |

UI sessions last 7 days (sliding) and are kept in memory, so you sign in again after a restart.

## Security notes

- Anyone who can reach the port can use the reverse proxy and, without `PROXYPIN_PASSWORD`, the UI.
  The UI can run scripts on the server and read and write files in the data directory.
- Captured traffic can contain credentials and personal data. It is kept in memory and in saved
  history/favorites under `/data`.
- The data directory also holds the generated CA private key (used when ProxyPin itself sends HTTPS
  requests on your behalf, for example Repeat).

## Run from source (without Docker)

Requires the Flutter version in `.fvmrc`, and Node.js 18+ for scripts.

```bash
flutter build web --release --base-href /__proxypin/ --no-web-resources-cdn
dart run bin/proxypin_server.dart          # serves build/web, data in ./data
```

## How it is built

- `bin/proxypin_server.dart` + `lib/server/`: headless server (plain Dart VM, no Flutter). It runs the
  ProxyPin network engine with a reverse-proxy front door (`lib/network/components/reverse_proxy/`) and
  serves the UI, a REST API and a WebSocket event stream under `/__proxypin/`.
- `lib/web/`: the browser side. `RemoteProxyServer` mirrors the server's capture events into the desktop
  UI, file access goes through the API (`lib/utils/io.dart` picks `dart:io` or the web shim), and
  multi-window calls are delivered in-page.
- The same `lib/` still compiles for the desktop and mobile apps, and the native project folders are
  unchanged. Platform-specific pieces are selected with conditional imports (`dart.library.js_interop` =
  web, `dart.library.ui` = Flutter, else server).
