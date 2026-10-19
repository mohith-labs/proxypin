# End-to-end tests

These drive a **running** ProxyPin web server over its real HTTP API, as the browser does. They cover the
parts that unit tests cannot: the file API's ownership merge, the live websocket capture feed, and the
admin-only endpoints.

## Running them

Start a server bound to loopback with the test login hook enabled:

```bash
dart build cli -t bin/proxypin_server.dart -o /tmp/proxypin_out

PROXYPIN_DATA_DIR=/tmp/pp_data \
PROXYPIN_HOME=$PWD \
PROXYPIN_WEB_DIR=$PWD/build/web \
PROXYPIN_GOOGLE_CLIENT_ID=test-client-id.apps.googleusercontent.com \
PROXYPIN_GOOGLE_CLIENT_SECRET=dummy \
PROXYPIN_ADMIN_EMAIL=admin@example.com \
PROXYPIN_PUBLIC_URL=http://127.0.0.1:18080 \
PROXYPIN_TEST_LOGIN=1 \
PROXYPIN_BIND=127.0.0.1 \
PORT=18080 \
/tmp/proxypin_out/bundle/bin/proxypin_server
```

Then, against that server:

```bash
python3 test/e2e/ownership_test.py         http://127.0.0.1:18080
python3 test/e2e/traffic_isolation_test.py http://127.0.0.1:18080
```

Both exit non-zero when a check fails. They need only the standard library.

`PROXYPIN_ADMIN_EMAIL` must be `mohith.code@gmail.com` for the scripts as written, or edit the admin
address at the top of each file.

## PROXYPIN_TEST_LOGIN

The scripts need several signed-in users, which Google cannot provide unattended. `PROXYPIN_TEST_LOGIN=1`
opens `POST /__proxypin/api/test/login`, which mints a session for an email address.

It is an authentication bypass, so:

- it does not exist unless the variable is set to `1`/`true`,
- it refuses to work unless the server is bound to loopback,
- the server logs a warning at startup while it is on.

Accounts minted this way still go through the normal signup, approval and domain rules, so the tests
exercise the real authorization path. **Never set it in production.**

## What they cover

`ownership_test.py` (27 checks)
- a route belongs to its creator; others cannot see, edit, claim or delete it
- a user's save does not destroy routes they cannot see (the server merges instead of overwriting)
- overlapping paths are refused across users
- the common path prefix: new routes land under it, two users may reuse a name, renaming moves the owner's
  routes and leaves everyone else's alone
- admin-only endpoints reject ordinary users
- the retention window can be set, swept and turned off
- an admin may edit somebody's route without taking ownership

`traffic_isolation_test.py` (11 checks)
- real traffic through each route, read back from each console's live websocket feed
- each user sees only their own route's traffic; unowned traffic is admin-only; the admin sees everything
- clearing traffic removes only the caller's own exchanges
