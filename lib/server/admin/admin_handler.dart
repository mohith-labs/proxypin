import 'dart:convert';

import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/server/server_environment.dart';

import '../proxypin_web_server.dart';
import 'admin_api.dart';
import 'admin_http.dart';
import 'admin_websocket.dart';
import 'static_files.dart';

/// Answers everything below `/__proxypin` (the web UI, its API and event stream) on the shared listener.
/// These exchanges never reach the capture pipeline.
class AdminHandler {
  static const int _snapshotChunk = 100;

  final ProxyPinWebServer server;
  final AdminApi api;
  final StaticFiles staticFiles;

  AdminHandler(this.server)
      : api = AdminApi(server),
        staticFiles = StaticFiles(ServerEnvironment.webDir);

  static const prefix = ServerEnvironment.uiPrefix;

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

  Future<void> _api(ChannelContext channelContext, Channel channel, HttpRequest request, String path,
      Map<String, String> query) async {
    switch (path) {
      case 'session':
        await _write(channelContext, channel, request, AdminHttp.json(_session(request)));
        return;
      case 'login':
        final body = AdminHttp.jsonBody(request);
        if (!server.auth.verify(body['username']?.toString(), body['password']?.toString())) {
          await Future.delayed(const Duration(milliseconds: 400)); // slow down guessing
          await _write(channelContext, channel, request, AdminHttp.error(401, 'invalid username or password'));
          return;
        }
        final response = AdminHttp.json({'ok': true});
        if (server.auth.enabled) response.headers.set('Set-Cookie', server.auth.login());
        await _write(channelContext, channel, request, response);
        return;
      case 'logout':
        final response = AdminHttp.json({'ok': true})..headers.set('Set-Cookie', server.auth.logout(request));
        await _write(channelContext, channel, request, response);
        return;
    }

    if (!server.auth.isAuthenticated(request)) {
      await _write(channelContext, channel, request, AdminHttp.error(401, 'login required'));
      return;
    }

    if (path == 'ws') {
      await _openEvents(channelContext, channel, request);
      return;
    }

    await _write(channelContext, channel, request, await api.handle(request, path, query));
  }

  Map<String, dynamic> _session(HttpRequest request) => {
        'authRequired': server.auth.enabled,
        'authenticated': server.auth.isAuthenticated(request),
        if (server.auth.enabled) 'user': ServerEnvironment.username,
      };

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

    socket.sendJson({'type': 'hello', 'info': api.info()});
    for (final event in server.breakpoints.pendingEvents) {
      socket.sendJson(event);
    }
    final snapshot = server.hub.snapshot();
    for (var i = 0; i < snapshot.length; i += _snapshotChunk) {
      final end = i + _snapshotChunk < snapshot.length ? i + _snapshotChunk : snapshot.length;
      socket.sendText(jsonEncode({'type': 'snapshot', 'items': snapshot.sublist(i, end)}));
    }
    socket.sendJson({'type': 'ready'});
    server.hub.subscribe(subscriber);
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

  static HttpResponse _uiMissing() => AdminHttp.bytes(
      503,
      utf8.encode('<!doctype html><title>ProxyPin</title><h3>ProxyPin web UI is not built</h3>'
          '<p>Build it with <code>flutter build web --base-href $prefix/</code> and point PROXYPIN_WEB_DIR at '
          'build/web. The API under <code>$prefix/api/</code> is available.</p>'),
      contentType: 'text/html; charset=utf-8');
}
