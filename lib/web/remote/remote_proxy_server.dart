import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/remote/wire.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/launch/launch.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/ui/component/multi_window_compat_web.dart' as windows;
import 'package:proxypin/web/remote/api_client.dart';
import 'package:proxypin/web/web_environment.dart';
import 'package:web/web.dart' as web;

import 'config_sync.dart';

enum RemoteConnection { connecting, connected, disconnected }

/// The web UI's [ProxyServer]: the real engine runs on the ProxyPin server, this mirrors it over a WebSocket.
///
/// Capture events are replayed to the UI's EventListeners exactly like the in-process engine emits them, so the
/// desktop request list, detail panel, WebSocket view, breakpoints and script console work unchanged.
/// Starting/stopping maps to the server's capture switch (traffic keeps flowing through the reverse proxy).
class RemoteProxyServer extends ProxyServer {
  RemoteProxyServer(super.configuration) {
    // the toolbar's start/stop button follows the server's capture switch (shared by every browser tab)
    capturing.addListener(() => SocketLaunch.startStatus.value = ValueWrap.of(capturing.value));
  }

  static RemoteProxyServer? get instance => ProxyServer.current is RemoteProxyServer ? ProxyServer.current as RemoteProxyServer : null;

  final ValueNotifier<RemoteConnection> connection = ValueNotifier(RemoteConnection.connecting);
  final ValueNotifier<bool> capturing = ValueNotifier(true);

  /// Requests known to this tab, by id (insertion ordered, trimmed).
  final LinkedHashMap<String, HttpRequest> _requests = LinkedHashMap();
  static const int _maxRequests = 10000;

  web.WebSocket? _socket;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  int _attempt = 0;
  Server? _placeholder;

  @override
  bool get isRunning => capturing.value;

  /// The event stream opens once the UI listens, so the session backlog reaches it.
  @override
  void addListener(EventListener listener) {
    super.addListener(listener);
    connect();
  }

  @override
  int get port => WebEnvironment.port;

  @override
  Future<Server> start() async {
    connect();
    if (!capturing.value) await setCapturing(true);
    return _placeholder ??= Server(configuration);
  }

  @override
  Future<Server?> stop() async {
    await setCapturing(false);
    return _placeholder;
  }

  @override
  Future<void> restart() async {
    await start();
  }

  @override
  Future<void> retryBind() async {}

  @override
  Future<void> setSystemProxyEnable(bool enable) async {}

  Future<void> setCapturing(bool enabled) async {
    final result = await ApiClient.postJson('capture', json: {'enabled': enabled});
    capturing.value = result['capturing'] != false;
  }

  /// Clears the server's session too, so a reload (or another tab) does not bring the requests back.
  @override
  Future<void> clearSession() async {
    _requests.clear();
    await ApiClient.postJson('traffic/clear');
  }

  // --------------------------------------------------------------------------------------------- connection

  /// Opens (or keeps) the event stream; independent of the capture switch.
  void connect() {
    if (_socket != null) return;
    _reconnectTimer?.cancel();
    final base = Uri.base;
    final url = '${base.scheme == 'https' ? 'wss' : 'ws'}://${base.host}${base.hasPort ? ':${base.port}' : ''}'
        '${WebEnvironment.apiBase}/ws';
    connection.value = RemoteConnection.connecting;

    final socket = web.WebSocket(url);
    _socket = socket;
    socket.onopen = ((web.Event _) {
      _attempt = 0;
      connection.value = RemoteConnection.connected;
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) => _send({'type': 'ping'}));
    }).toJS;
    socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (data != null && data.typeofEquals('string')) _onMessage((data as JSString).toDart);
    }).toJS;
    socket.onclose = ((web.CloseEvent _) => _onClosed(socket)).toJS;
  }

  void _onClosed(web.WebSocket socket) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    _pingTimer?.cancel();
    connection.value = RemoteConnection.disconnected;
    final delay = Duration(milliseconds: (500 * (1 << _attempt.clamp(0, 4))).clamp(500, 8000));
    _attempt++;
    _reconnectTimer = Timer(delay, connect);
  }

  void _send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket != null && socket.readyState == web.WebSocket.OPEN) socket.send(jsonEncode(message).toJS);
  }

  // ------------------------------------------------------------------------------------------------- events

  void _onMessage(String text) {
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(text);
    } catch (e) {
      logger.w('bad event: $e');
      return;
    }

    try {
      switch (message['type']) {
        case 'hello':
          final info = Map<String, dynamic>.from(message['info'] ?? const {});
          WebEnvironment.apply(info);
          capturing.value = info['capturing'] != false;
        case 'snapshot':
          for (final item in (message['items'] as List? ?? const [])) {
            _onSnapshotItem(Map<String, dynamic>.from(item));
          }
        case 'request':
          _addRequest(Wire.requestFrom(Map<String, dynamic>.from(message['request'])));
        case 'response':
          _addResponse(Map<String, dynamic>.from(message['response']));
        case 'frame':
          _addFrame(message);
        case 'breakpoint':
          _openBreakpoint(message);
        case 'breakpointResolved':
          _closeBreakpoint(message['requestId'], message['isResponse'] == true);
        case 'scriptLog':
          ScriptManager.publishLog(LogInfo.fromJson(Map<String, dynamic>.from(message['log'])));
        case 'capture':
          capturing.value = message['capturing'] != false;
        case 'cleared':
          _requests.clear();
          onSessionCleared?.call();
        case 'configChanged':
          ConfigSync.onChanged(message);
      }
    } catch (e, t) {
      logger.e('event ${message['type']} failed', error: e, stackTrace: t);
    }
  }

  void _onSnapshotItem(Map<String, dynamic> item) {
    final requestJson = Map<String, dynamic>.from(item['request']);
    final known = _requests[requestJson['id']];
    if (known == null) {
      _addRequest(Wire.requestFrom(requestJson));
    }
    final response = item['response'];
    if (response != null && (known == null || known.response == null)) {
      _addResponse(Map<String, dynamic>.from(response));
    }
  }

  void _addRequest(HttpRequest request) {
    if (_requests.containsKey(request.requestId)) return; // engine may announce a failed request twice
    _requests[request.requestId] = request;
    if (_requests.length > _maxRequests) _requests.remove(_requests.keys.first);
    for (final listener in List.of(listeners)) {
      listener.onRequest(null, request);
    }
  }

  void _addResponse(Map<String, dynamic> json) {
    final request = _requests[json['requestId']];
    if (request == null) return;
    final response = Wire.responseFrom(json, request: request);
    final context = ChannelContext()..currentRequest = request;
    for (final listener in List.of(listeners)) {
      listener.onResponse(context, response);
    }
  }

  void _addFrame(Map<String, dynamic> message) {
    final request = _requests[message['requestId']];
    if (request == null) return;
    final frame = Wire.frameFrom(Map<String, dynamic>.from(message['frame']));
    final HttpMessage? target = message['target'] == 'request' ? request : request.response;
    if (target == null) return;
    target.messages.add(frame);
    for (final listener in List.of(listeners)) {
      listener.onMessage(null, target, frame);
    }
  }

  // --------------------------------------------------------------------------------------------- breakpoints

  void _openBreakpoint(Map<String, dynamic> message) {
    final args = Map<String, dynamic>.from(message['args']);
    final requestId = args['requestId'];
    // one editor per paused message (a reconnect re-sends the pending ones)
    final open = _breakpointWindows(requestId, args['type'] == 'response');
    if (open.isNotEmpty) return;
    MultiWindow.openWindow(message['title'] ?? 'Breakpoint', 'BreakpointExecutor', args: args);
  }

  void _closeBreakpoint(String? requestId, bool isResponse) {
    if (requestId == null) return;
    for (final id in _breakpointWindows(requestId, isResponse)) {
      windows.WindowController.fromWindowId(id).close();
    }
  }

  static Iterable<String> _breakpointWindows(String? requestId, bool isResponse) => windows.WebWindows.where((args) =>
      args['name'] == 'BreakpointExecutor' &&
      args['requestId'] == requestId &&
      (args['type'] == 'response') == isResponse);
}
