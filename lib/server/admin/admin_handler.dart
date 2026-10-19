import 'dart:convert';

import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/server/auth/auth_store.dart';
import 'package:proxypin/server/auth/google_oauth.dart';
import 'package:proxypin/server/server_environment.dart';

import '../proxypin_web_server.dart';
import 'admin_api.dart';
import 'admin_http.dart';
import 'admin_websocket.dart';
import 'static_files.dart';

/// Answers everything below `/__proxypin` (the web UI, its API, the Google sign-in routes and the event
/// stream) on the shared listener. These exchanges never reach the capture pipeline.
class AdminHandler {
  static const int _snapshotChunk = 100;

  final ProxyPinWebServer server;
  final AdminApi api;
  final StaticFiles staticFiles;

  AdminHandler(this.server)
      : api = AdminApi(server),
        staticFiles = StaticFiles(ServerEnvironment.webDir);

  static const prefix = ServerEnvironment.uiPrefix;

  /// Path of the OAuth callback, which must match the redirect URI registered with Google.
  static const String callbackPath = '$prefix/auth/google/callback';

  Future<bool> handle(ChannelContext channelContext, Channel channel, HttpRequest request) async {
    final uri = Uri.tryParse(request.uri.startsWith('/') ? 'http://local${request.uri}' : request.uri);
    if (uri == null) return false;
    final path = uri.path;
    if (path != prefix && !path.startsWith('$prefix/')) return false;

    try {
      if (path == prefix) {
        await _write(channelContext, channel, request, AdminHttp.redirect('$prefix/'));
        return true;
      }

      final relative = path.substring(prefix.length + 1);
      if (relative.startsWith('auth/google/')) {
        await _googleAuth(channelContext, channel, request, relative.substring(12), uri.queryParameters);
        return true;
      }
      if (relative.startsWith('api/')) {
        await _api(channelContext, channel, request, relative.substring(4), uri.queryParameters);
        return true;
      }

      if (!staticFiles.available) {
        await _write(channelContext, channel, request, _uiMissing());
        return true;
      }
      await _write(channelContext, channel, request, await staticFiles.serve(request, relative));
    } catch (e, t) {
      logger.e('admin request $path failed', error: e, stackTrace: t);
      if (!channel.isClosed) await _write(channelContext, channel, request, AdminHttp.error(500, e.toString()));
    }
    return true;
  }

  /// Mints a session without Google, for end-to-end tests (PROXYPIN_TEST_LOGIN=1).
  ///
  /// This bypasses authentication, so it exists only when the variable is set AND the server listens on
  /// loopback; the account still goes through the normal signup/domain rules, so what the tests exercise is
  /// the real authorization path.
  Future<HttpResponse> _testLogin(HttpRequest request) async {
    if (!ServerEnvironment.testLoginEnabled) return AdminHttp.error(404, 'not found');
    if (!ServerEnvironment.boundToLoopback) {
      return AdminHttp.error(403, 'PROXYPIN_TEST_LOGIN only works when the server is bound to loopback');
    }

    final body = AdminHttp.jsonBody(request);
    final email = body['email']?.toString().trim().toLowerCase() ?? '';
    if (email.isEmpty) return AdminHttp.error(400, 'email required');

    final result = await server.authStore.signIn(
      subject: 'test-${base64Url.encode(utf8.encode(email)).replaceAll('=', '')}',
      email: email,
      name: body['name']?.toString() ?? email,
      picture: '',
    );
    final user = result.user;
    if (user == null) return AdminHttp.error(403, result.error ?? 'not allowed');

    final cookie = server.auth.login(user);
    final token = cookie.split(';').first.split('=').last;
    return AdminHttp.json({'token': token, 'user': user.toPublicJson()});
  }

  // -------------------------------------------------------------------------------------- Google sign-in

  /// The redirect URI handed to Google. It must be identical when starting the flow and when exchanging the
  /// code, so both calls derive it the same way: PROXYPIN_PUBLIC_URL if set, else the request's own origin.
  static String redirectUri(HttpRequest request) => '${_origin(request)}$callbackPath';

  static String _origin(HttpRequest request) {
    final configured = ServerEnvironment.publicUrl;
    if (configured != null) return configured;
    final host = request.headers.get('X-Forwarded-Host') ?? request.headers.get('Host') ?? '127.0.0.1:${ServerEnvironment.port}';
    final scheme = request.headers.get('X-Forwarded-Proto') ?? 'http';
    return '$scheme://$host';
  }

  Future<void> _googleAuth(ChannelContext channelContext, Channel channel, HttpRequest request, String action,
      Map<String, String> query) async {
    final oauth = server.oauth;
    if (!oauth.configured) {
      await _write(channelContext, channel, request,
          _signInPage('Google sign-in is not configured', 'Set PROXYPIN_GOOGLE_CLIENT_ID and '
              'PROXYPIN_GOOGLE_CLIENT_SECRET on the server, then reload this page.'));
      return;
    }

    switch (action) {
      case 'start':
        final url = oauth.authorizationUrl(redirectUri: redirectUri(request), returnTo: query['returnTo']);
        await _write(channelContext, channel, request, AdminHttp.redirect(url));
        return;

      case 'callback':
        final error = query['error'];
        if (error != null) {
          await _write(channelContext, channel, request, _signInPage('Sign-in cancelled', 'Google reported: $error'));
          return;
        }

        final pending = oauth.takeState(query['state']);
        final code = query['code'];
        if (pending == null || code == null) {
          await _write(channelContext, channel, request,
              _signInPage('Sign-in expired', 'This sign-in link is no longer valid. Please try again.'));
          return;
        }

        try {
          final profile = await oauth.exchange(code, redirectUri(request));
          final store = await AuthStore.instance;
          final result = await store.signIn(
            subject: profile.subject,
            email: profile.email,
            name: profile.name,
            picture: profile.picture,
          );

          if (!result.allowed) {
            await _write(channelContext, channel, request, _signInPage('Access denied', result.error!));
            return;
          }

          if (result.pending) {
            await _write(
                channelContext,
                channel,
                request,
                _signInPage('Waiting for approval',
                    'Your request to access this console has been sent to the administrator. '
                    'You will be able to sign in once it is approved.'));
            return;
          }

          final response = AdminHttp.redirect(pending.returnTo ?? '$prefix/')
            ..headers.set('Set-Cookie', server.auth.login(result.user!));
          logger.i('sign-in: ${result.user!.email}${result.user!.isAdmin ? ' (admin)' : ''}');
          await _write(channelContext, channel, request, response);
        } on OAuthException catch (e) {
          await _write(channelContext, channel, request, _signInPage('Sign-in failed', e.message));
        }
        return;
    }

    await _write(channelContext, channel, request, AdminHttp.error(404, 'unknown auth endpoint'));
  }

  // --------------------------------------------------------------------------------------------- API

  Future<void> _api(ChannelContext channelContext, Channel channel, HttpRequest request, String path,
      Map<String, String> query) async {
    if (path == 'session') {
      await _write(channelContext, channel, request, AdminHttp.json(_session(request)));
      return;
    }
    if (path == 'logout') {
      final response = AdminHttp.json({'ok': true})..headers.set('Set-Cookie', server.auth.logout(request));
      await _write(channelContext, channel, request, response);
      return;
    }
    if (path == 'test/login') {
      await _write(channelContext, channel, request, await _testLogin(request));
      return;
    }

    final user = server.auth.currentUser(request);
    if (user == null) {
      await _write(channelContext, channel, request, AdminHttp.error(401, 'login required'));
      return;
    }

    if (path == 'ws') {
      await _openEvents(channelContext, channel, request);
      return;
    }

    await _write(channelContext, channel, request, await api.handle(request, path, query, user));
  }

  Map<String, dynamic> _session(HttpRequest request) {
    final user = server.auth.currentUser(request);
    return {
      'authRequired': true,
      'authenticated': user != null,
      'googleConfigured': server.oauth.configured,
      'adminConfigured': ServerEnvironment.adminEmails.isNotEmpty,
      'signInUrl': '$prefix/auth/google/start',
      if (user != null) 'user': user.toPublicJson(),
    };
  }

  /// Event stream for one browser tab: hello (info + paused breakpoints), the session backlog, then live events.
  Future<void> _openEvents(ChannelContext channelContext, Channel channel, HttpRequest request) async {
    final socket = await AdminWebSocket.upgrade(channelContext, channel, request);
    if (socket == null) {
      await _write(channelContext, channel, request, AdminHttp.error(400, 'websocket upgrade required'));
      return;
    }

    final subscriber = socket.sendText;
    socket.onClose = () => server.hub.unsubscribe(subscriber);
    socket.onMessage = (message) {
      // the UI only sends keep-alives; reply so it can detect a dead connection
      if (message.contains('"ping"')) socket.sendText('{"type":"pong"}');
    };

    final viewer = server.auth.currentUser(request);
    final userId = viewer?.id ?? '';
    final isAdmin = viewer?.isAdmin == true;

    socket.sendJson({'type': 'hello', 'info': api.info(viewer)});
    for (final event in server.breakpoints.pendingEvents) {
      socket.sendJson(event);
    }
    // only the traffic this user's own routes carried (admins see everything)
    final snapshot = server.hub.snapshot(userId: userId, isAdmin: isAdmin);
    for (var i = 0; i < snapshot.length; i += _snapshotChunk) {
      final end = i + _snapshotChunk < snapshot.length ? i + _snapshotChunk : snapshot.length;
      socket.sendText(jsonEncode({'type': 'snapshot', 'items': snapshot.sublist(i, end)}));
    }
    socket.sendJson({'type': 'ready'});
    server.hub.subscribe(subscriber, userId: userId, isAdmin: isAdmin);
  }

  static Future<void> _write(ChannelContext channelContext, Channel channel, HttpRequest request, HttpResponse response) async {
    response.protocolVersion = HttpMessage.http1Version;
    if (request.headers.get('Connection')?.toLowerCase() == 'close') {
      response.headers.set('Connection', 'close');
      await channel.writeAndClose(channelContext, response);
      return;
    }
    await channel.write(channelContext, response);
  }

  /// Server-rendered page for the states the Flutter UI cannot show (it is not loaded at that point).
  static HttpResponse _signInPage(String title, String message) => AdminHttp.bytes(
      200,
      utf8.encode('<!doctype html><html><head><meta charset="utf-8"><title>ProxyPin</title>'
          '<meta name="viewport" content="width=device-width,initial-scale=1">'
          '<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f6f7f9;color:#1f2328;'
          'display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}'
          '.card{background:#fff;border-radius:12px;box-shadow:0 1px 3px rgba(0,0,0,.12);padding:32px;max-width:420px;text-align:center}'
          'h1{font-size:19px;margin:0 0 10px}p{font-size:14px;line-height:1.55;color:#57606a;margin:0 0 20px}'
          'a{display:inline-block;background:#1a73e8;color:#fff;text-decoration:none;padding:9px 20px;border-radius:6px;font-size:14px}'
          '@media(prefers-color-scheme:dark){body{background:#16181c;color:#e6edf3}.card{background:#22262c;box-shadow:none}p{color:#9aa4b2}}'
          '</style></head><body><div class="card"><h1>$title</h1><p>$message</p>'
          '<a href="$prefix/">Back to ProxyPin</a></div></body></html>'),
      contentType: 'text/html; charset=utf-8');

  static HttpResponse _uiMissing() => AdminHttp.bytes(
      503,
      utf8.encode('<!doctype html><title>ProxyPin</title><h3>ProxyPin web UI is not built</h3>'
          '<p>Build it with <code>flutter build web --base-href $prefix/</code> and point PROXYPIN_WEB_DIR at '
          'build/web. The API under <code>$prefix/api/</code> is available.</p>'),
      contentType: 'text/html; charset=utf-8');
}
