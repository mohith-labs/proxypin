#!/usr/bin/env python3
"""End-to-end check of ProxyPin per-user reverse-proxy ownership against a RUNNING server.

Signs in two users and an admin by minting sessions through the server's own test hook, then drives the real
HTTP API exactly as the browser does.
"""
import json
import sys
import urllib.error
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:18080"
API = f"{BASE}/__proxypin/api"
RP = None  # resolved from the server's own data directory once signed in

results = []


def call(method, path, token=None, body=None, raw=False):
    url = f"{API}/{path}"
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    if token:
        req.add_header("Cookie", f"proxypin_session={token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            payload = r.read()
            if raw:
                return r.status, payload
            return r.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        payload = e.read()
        try:
            return e.code, json.loads(payload)
        except Exception:
            return e.code, {"error": payload.decode(errors="replace")}


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  -- {detail}" if detail and not ok else ""))


def mint(email, name):
    """Mint a session through the server's test hook (enabled by PROXYPIN_TEST_LOGIN)."""
    status, body = call("POST", "test/login", body={"email": email, "name": name})
    if status != 200:
        print(f"could not mint a session for {email}: HTTP {status} {body}")
        sys.exit(2)
    return body["token"], body["user"]


def resolve_rules_path(token):
    """The reverse proxy config lives in the server's data directory, whatever that is."""
    status, info = call("GET", "info", token=token)
    if status != 200:
        print(f"could not read server info: HTTP {status} {info}")
        sys.exit(2)
    sep = info.get("pathSeparator", "/")
    return f"{info['dataDir']}{sep}reverse_proxy.json"


def write_rules(token, rules, enabled=True):
    payload = json.dumps({"enabled": enabled, "rules": rules}).encode()
    return call("PUT", f"fs/write?path={RP}", token=token, body=payload)


def read_rules(token):
    status, body = call("GET", f"fs/read?path={RP}", token=token, raw=True)
    if status != 200:
        return status, []
    return status, json.loads(body).get("rules", [])


def rule(path, target="https://example.com", owner=None):
    r = {"enabled": True, "name": "", "path": path, "target": target,
         "stripPrefix": True, "preserveHost": False, "rewriteResponse": True}
    if owner:
        r["ownerId"] = owner
    return r


print(f"ProxyPin ownership end-to-end against {BASE}\n")

alice_t, alice = mint("alice@example.com", "Alice")
bob_t, bob = mint("bob@example.com", "Bob")
admin_t, admin = mint("mohith.code@gmail.com", "Admin")
RP = resolve_rules_path(admin_t)
print(f"signed in: alice={alice['id'][:12]} bob={bob['id'][:12]} admin={admin['id'][:12]} (admin={admin['isAdmin']})")
print(f"rules file: {RP}\n")

# start from a clean slate
write_rules(admin_t, [])

print("1. ownership of paths")
status, _ = write_rules(alice_t, [rule("/test")])
check("alice creates /test", status == 200, f"HTTP {status}")

status, rules = read_rules(alice_t)
check("alice sees her own rule", [r["path"] for r in rules] == ["/test"], str([r["path"] for r in rules]))
check("the rule is stamped with alice", rules and rules[0].get("ownerId") == alice["id"])

status, rules = read_rules(bob_t)
check("bob cannot see alice's rule", rules == [], str(rules))

status, rules = read_rules(admin_t)
check("the admin sees alice's rule", [r["path"] for r in rules] == ["/test"], str([r["path"] for r in rules]))

print("\n2. a user cannot take over or destroy another's route")
status, body = write_rules(bob_t, [rule("/test")])
check("bob cannot claim /test", status == 409, f"HTTP {status} {body.get('error', '')}")

status, body = write_rules(bob_t, [rule("/test", owner=alice["id"])])
check("bob cannot forge alice's owner id", status == 409, f"HTTP {status}")

# bob saves his own world; alice's rule must survive even though bob never sent it
status, _ = write_rules(bob_t, [rule("/bobs")])
check("bob creates /bobs", status == 200, f"HTTP {status}")
status, rules = read_rules(admin_t)
paths = sorted(r["path"] for r in rules)
check("alice's rule survived bob's write", paths == ["/bobs", "/test"], str(paths))

status, _ = write_rules(bob_t, [])
status, rules = read_rules(admin_t)
paths = sorted(r["path"] for r in rules)
check("bob deleting his rules left alice's alone", paths == ["/test"], str(paths))

print("\n3. overlapping paths are refused")
status, body = write_rules(bob_t, [rule("/test/inner")])
check("bob cannot nest under alice's /test", status == 409, f"HTTP {status}")
status, _ = write_rules(bob_t, [rule("/elsewhere")])
check("a non-overlapping path is accepted", status == 200, f"HTTP {status}")
write_rules(admin_t, [r for r in read_rules(admin_t)[1] if r["path"] != "/elsewhere"])

print("\n4. common path prefix")
status, body = call("POST", "me/prefix", token=bob_t, body={"prefix": "/user2"})
check("bob sets the prefix /user2", status == 200 and body.get("user", {}).get("pathPrefix") == "/user2",
      f"HTTP {status} {body}")

status, _ = write_rules(bob_t, [rule("/test")])
check("bob may now use the name /test too", status == 200, f"HTTP {status}")
status, rules = read_rules(bob_t)
check("bob's rule became /user2/test", [r["path"] for r in rules] == ["/user2/test"], str([r["path"] for r in rules]))

status, rules = read_rules(admin_t)
paths = sorted(r["path"] for r in rules)
check("both routes coexist", paths == ["/test", "/user2/test"], str(paths))

status, body = call("POST", "me/prefix", token=bob_t, body={"prefix": "/renamed"})
check("bob renames his prefix", status == 200, f"HTTP {status}")
status, rules = read_rules(bob_t)
check("his existing route moved", [r["path"] for r in rules] == ["/renamed/test"], str([r["path"] for r in rules]))

status, rules = read_rules(alice_t)
check("alice's route was not moved", [r["path"] for r in rules] == ["/test"], str([r["path"] for r in rules]))

print("\n5. admin-only endpoints")
status, _ = call("POST", "admin/traffic/sweep", token=alice_t, body={})
check("a user cannot sweep traffic", status == 403, f"HTTP {status}")
status, body = call("GET", "admin/users", token=alice_t)
check("a user cannot list users", status == 403, f"HTTP {status}")

status, body = call("POST", "admin/settings", token=admin_t, body={"retentionHours": 24})
check("the admin sets a 24h retention window",
      status == 200 and body.get("settings", {}).get("retentionHours") == 24, f"HTTP {status} {body}")
status, body = call("POST", "admin/traffic/sweep", token=admin_t, body={})
check("the admin can run the sweep", status == 200, f"HTTP {status} {body}")

status, body = call("POST", "admin/settings", token=admin_t, body={"retentionHours": 0})
check("retention can be turned off", status == 200 and body["settings"]["retentionHours"] == 0, f"HTTP {status}")
status, body = call("POST", "admin/traffic/sweep", token=admin_t, body={})
check("sweeping without a window is refused", status == 400, f"HTTP {status}")

print("\n6. the admin may edit anyone's route")
status, rules = read_rules(admin_t)
for r in rules:
    if r["path"] == "/test":
        r["target"] = "https://changed-by-admin.com"
status, _ = write_rules(admin_t, rules)
check("the admin edits alice's route", status == 200, f"HTTP {status}")
status, rules = read_rules(alice_t)
check("the edit landed and alice still owns it",
      rules and rules[0]["target"] == "https://changed-by-admin.com" and rules[0]["ownerId"] == alice["id"],
      str(rules))

# tidy up
write_rules(admin_t, [])
call("POST", "me/prefix", token=bob_t, body={"prefix": ""})

passed = sum(1 for _, ok, _ in results if ok)
print(f"\n{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
