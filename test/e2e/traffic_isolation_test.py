#!/usr/bin/env python3
"""End-to-end check that captured traffic reaches only the user whose route carried it.

Starts a local upstream, gives two users a route each, sends real traffic through both, and reads every
console's live websocket feed to see which exchanges it was shown.
"""
import json
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:18080"
API = f"{BASE}/__proxypin/api"
HOST, PORT = BASE.split("//")[1].split(":")
PORT = int(PORT)

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  -- {detail}" if detail and not ok else ""))


def call(method, path, token=None, body=None, raw=False):
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
    req = urllib.request.Request(f"{API}/{path}", data=data, method=method)
    if token:
        req.add_header("Cookie", f"proxypin_session={token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            payload = r.read()
            return r.status, (payload if raw else (json.loads(payload) if payload else {}))
    except urllib.error.HTTPError as e:
        payload = e.read()
        try:
            return e.code, json.loads(payload)
        except Exception:
            return e.code, {"error": payload.decode(errors="replace")}


# ---------------------------------------------------------------- a minimal upstream to proxy to
class Upstream(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(f"upstream saw {self.path}".encode())

    def log_message(self, *args):
        pass


upstream = HTTPServer(("127.0.0.1", 0), Upstream)
threading.Thread(target=upstream.serve_forever, daemon=True).start()
UP = f"http://127.0.0.1:{upstream.server_port}"


# ---------------------------------------------------------------- a tiny websocket client (RFC 6455, no deps)
class WS:
    """Reads text frames from the console feed; enough of the protocol for an unmasked server stream."""

    def __init__(self, token):
        self.sock = socket.create_connection((HOST, PORT), timeout=20)
        key = "x3JJHMbDL1EzLkh9GBhXDw=="
        self.sock.sendall(
            f"GET /__proxypin/api/ws HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
            f"Cookie: proxypin_session={token}\r\n\r\n".encode()
        )
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("websocket handshake failed")
            self.buf += chunk
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError(f"websocket upgrade refused: {head.splitlines()[0]}")
        self.buf = rest
        self.events = []
        self.alive = True
        threading.Thread(target=self._pump, daemon=True).start()

    def _recv(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _pump(self):
        try:
            while self.alive:
                b1, b2 = self._recv(2)
                opcode = b1 & 0x0F
                length = b2 & 0x7F
                if length == 126:
                    length = int.from_bytes(self._recv(2), "big")
                elif length == 127:
                    length = int.from_bytes(self._recv(8), "big")
                payload = self._recv(length) if length else b""
                if opcode == 1:
                    try:
                        self.events.append(json.loads(payload.decode()))
                    except Exception:
                        pass
                elif opcode == 8:
                    break
        except Exception:
            pass
        self.alive = False

    def close(self):
        self.alive = False
        try:
            self.sock.close()
        except Exception:
            pass

    def urls(self):
        """Every request URL this console was shown, from the backlog and the live feed."""
        seen = []
        for e in list(self.events):
            if e.get("type") == "request":
                seen.append(e["request"].get("uri", ""))
            elif e.get("type") == "snapshot":
                for item in e.get("items", []):
                    seen.append(item.get("request", {}).get("uri", ""))
        return seen


def mint(email, name):
    status, body = call("POST", "test/login", body={"email": email, "name": name})
    if status != 200:
        print(f"could not sign in {email}: HTTP {status} {body}")
        sys.exit(2)
    return body["token"], body["user"]


def rules_path(token):
    _, info = call("GET", "info", token=token)
    sep = info.get("pathSeparator", "/")
    return f"{info['dataDir']}{sep}reverse_proxy.json"


def write_rules(token, rules):
    payload = json.dumps({"enabled": True, "rules": rules}).encode()
    return call("PUT", f"fs/write?path={RP}", token=token, body=payload)


def rule(path, owner=None):
    # stripPrefix off so the captured URL keeps the route name and the test can tell routes apart
    r = {"enabled": True, "name": "", "path": path, "target": UP,
         "stripPrefix": False, "preserveHost": False, "rewriteResponse": True}
    if owner:
        r["ownerId"] = owner
    return r


print(f"ProxyPin traffic isolation end-to-end against {BASE}")
print(f"upstream: {UP}\n")

alice_t, alice = mint("alice@example.com", "Alice")
bob_t, bob = mint("bob@example.com", "Bob")
admin_t, admin = mint("mohith.code@gmail.com", "Admin")
RP = rules_path(admin_t)

# alice owns /alice-route, bob owns /bob-route
write_rules(admin_t, [])
status, _ = write_rules(alice_t, [rule("/alice-route")])
assert status == 200, status
status, _ = write_rules(bob_t, [rule("/bob-route")])
assert status == 200, status
# an unowned route, as if it predated ownership
_, current = call("GET", f"fs/read?path={RP}", token=admin_t, raw=True)
rules = json.loads(current)["rules"] + [rule("/legacy-route")]
status, _ = call("PUT", f"fs/write?path={RP}", token=admin_t,
                 body=json.dumps({"enabled": True, "rules": rules}).encode())
assert status == 200, status
time.sleep(1.5)  # let the server reload the config

# clear anything captured while setting up, then connect the three consoles
call("POST", "traffic/clear", token=admin_t, body={})
time.sleep(0.5)
alice_ws, bob_ws, admin_ws = WS(alice_t), WS(bob_t), WS(admin_t)
time.sleep(1.5)

print("sending traffic through each route")
for path in ["/alice-route/ping", "/bob-route/ping", "/legacy-route/ping"]:
    try:
        urllib.request.urlopen(f"{BASE}{path}", timeout=10).read()
        print(f"  sent {path}")
    except Exception as e:
        print(f"  sent {path} ({e})")
time.sleep(3)

a, b, ad = alice_ws.urls(), bob_ws.urls(), admin_ws.urls()
alice_ws.close(); bob_ws.close(); admin_ws.close()


def saw(urls, needle):
    return any(needle in u for u in urls)


print(f"\nalice's console saw: {a}")
print(f"bob's console saw:   {b}")
print(f"admin's console saw: {ad}\n")

print("1. each user sees their own traffic")
check("alice sees her own route's traffic", saw(a, "/alice-route"), str(a))
check("bob sees his own route's traffic", saw(b, "/bob-route"), str(b))

print("\n2. users do not see each other's traffic")
check("alice does not see bob's traffic", not saw(a, "/bob-route"), str(a))
check("bob does not see alice's traffic", not saw(b, "/alice-route"), str(b))

print("\n3. unowned traffic is admin-only")
check("alice does not see unowned traffic", not saw(a, "/legacy-route"), str(a))
check("bob does not see unowned traffic", not saw(b, "/legacy-route"), str(b))

print("\n4. the admin sees everything")
check("admin sees alice's traffic", saw(ad, "/alice-route"), str(ad))
check("admin sees bob's traffic", saw(ad, "/bob-route"), str(ad))
check("admin sees unowned traffic", saw(ad, "/legacy-route"), str(ad))

print("\n5. a user clearing traffic does not wipe another's")
call("POST", "traffic/clear", token=alice_t, body={})
time.sleep(1)
late = WS(admin_t)
time.sleep(1.5)
remaining = late.urls()
late.close()
check("alice's clear removed her own traffic", not saw(remaining, "/alice-route"), str(remaining))
check("bob's traffic survived alice's clear", saw(remaining, "/bob-route"), str(remaining))

write_rules(admin_t, [])
upstream.shutdown()

passed = sum(1 for _, ok in results if ok)
print(f"\n{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
