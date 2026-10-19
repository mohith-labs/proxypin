import 'dart:convert';

import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_handler.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/remote/wire.dart';
import 'package:proxypin/utils/listenable_list.dart';

import 'content_decoding.dart';

/// Receives the engine's capture events, keeps the recent session for newly connected browsers (and for history
/// recording), and fans every event out to the web UI subscribers as JSON.
class CaptureHub extends EventListener {
  CaptureHub({required this.limit});

  /// Maximum requests kept in memory; the oldest are dropped first (like the desktop memory cleanup).
  final int limit;

  /// When false nothing is recorded (the interceptors are bypassed too, see ServerInterceptors).
  bool capturing = true;

  /// The capture session, also the source list of the server's HistoryTask.
  final ListenableList<HttpRequest> container = ListenableList();
  final Map<String, HttpRequest> _byId = {};

  /// A connected console, with the identity used to decide which exchanges it may see.
  final Map<void Function(String json), _Viewer> _subscribers = {};

  void subscribe(void Function(String json) subscriber, {required String userId, required bool isAdmin}) =>
      _subscribers[subscriber] = _Viewer(userId: userId, isAdmin: isAdmin);

  void unsubscribe(void Function(String json) subscriber) => _subscribers.remove(subscriber);

  int get subscriberCount => _subscribers.length;

  /// Sends [event] to every console, or only to those allowed to see [owner] when given.
  ///
  /// [owner] is the id of the user whose rule carried the exchange; an empty owner means the traffic matched no
  /// owned rule (or a rule from before ownership existed) and is shown to admins only.
  void broadcast(Map<String, dynamic> event, {String? owner}) {
    if (_subscribers.isEmpty) return;
    final json = jsonEncode(event);
    for (final entry in List.of(_subscribers.entries)) {
      if (owner != null && !entry.value.canSee(owner)) continue;
      entry.key(json);
    }
  }

  /// The owner id recorded on a captured request, or empty when it has none.
  static String ownerOf(HttpRequest request) {
    final route = request.attributes[ReverseProxyChannelHandler.routeAttribute];
    if (route is Map) return route['ownerId']?.toString() ?? '';
    return '';
  }

  /// Whether [userId] may see [request].
  static bool visibleTo(HttpRequest request, {required String userId, required bool isAdmin}) =>
      _Viewer(userId: userId, isAdmin: isAdmin).canSee(ownerOf(request));

  @override
  void onRequest(Channel? channel, HttpRequest request) {
    if (!capturing) return;
    _upsert(request);
    broadcast({'type': 'request', 'request': _request(request)}, owner: ownerOf(request));
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {
    if (!capturing) return;
    final request = response.request;
    if (request != null && !_byId.containsKey(request.requestId)) _upsert(request);
    broadcast({'type': 'response', 'response': _response(response, includeMessages: false)},
        owner: request == null ? '' : ownerOf(request));
  }

  @override
  void onMessage(Channel? channel, HttpMessage message, WebSocketFrame frame) {
    if (!capturing) return;
    final bool fromRequest = message is HttpRequest;
    final requestId = message is HttpResponse ? (message.request?.requestId ?? message.requestId) : message.requestId;
    final origin = _byId[requestId];
    broadcast({
      'type': 'frame',
      'requestId': requestId,
      'target': fromRequest ? 'request' : 'response',
      'frame': Wire.frame(frame),
    }, owner: origin == null ? '' : ownerOf(origin));
  }

  void _upsert(HttpRequest request) {
    final existing = _byId[request.requestId];
    if (existing != null) {
      if (!identical(existing, request)) {
        final index = container.indexOf(existing);
        if (index >= 0) container.update(index, request);
        _byId[request.requestId] = request;
      }
      return;
    }
    _byId[request.requestId] = request;
    container.add(request);
    // trim in batches: every removal makes a recording HistoryTask rewrite its file
    if (container.length > limit + (limit ~/ 10).clamp(1, 500)) {
      for (final request in container.removeRange(0, container.length - limit)) {
        _byId.remove(request.requestId);
      }
    }
  }

  /// Session backlog for a newly connected browser, limited to what [userId] may see.
  List<Map<String, dynamic>> snapshot({required String userId, required bool isAdmin}) {
    final viewer = _Viewer(userId: userId, isAdmin: isAdmin);
    return container
        .where((request) => viewer.canSee(ownerOf(request)))
        .map((request) => {
              'request': _request(request),
              if (request.response != null) 'response': _response(request.response!),
            })
        .toList();
  }

  static Map<String, dynamic> _request(HttpRequest request) =>
      Wire.request(request, decodedBody: ContentDecoding.decodedBody(request));

  static Map<String, dynamic> _response(HttpResponse response, {bool includeMessages = true}) =>
      Wire.response(response, includeMessages: includeMessages, decodedBody: ContentDecoding.decodedBody(response));

  void clear() {
    container.clear();
    _byId.clear();
    broadcast({'type': 'cleared'});
  }

  /// Drops the traffic [userId] is allowed to clear; returns how many exchanges were removed.
  ///
  /// An admin clears everything, a user only the exchanges their own routes carried, so one tenant cannot
  /// wipe another's capture session.
  int clearFor({required String userId, required bool isAdmin}) {
    if (isAdmin) {
      final removed = container.length;
      clear();
      return removed;
    }
    final viewer = _Viewer(userId: userId, isAdmin: false);
    final mine = container.where((request) => viewer.canSee(ownerOf(request))).toList();
    for (final request in mine) {
      container.remove(request);
      _byId.remove(request.requestId);
    }
    // only this user's consoles need to drop their rows
    broadcast({'type': 'cleared'}, owner: userId);
    return mine.length;
  }

  /// Drops captured traffic older than [age]; returns how many exchanges were removed.
  ///
  /// Used by the admin's retention schedule, which keeps a rolling window rather than wiping everything.
  int clearOlderThan(Duration age) {
    final cutoff = DateTime.now().subtract(age);
    final stale = container.where((request) => request.requestTime.isBefore(cutoff)).toList();
    if (stale.isEmpty) return 0;
    for (final request in stale) {
      container.remove(request);
      _byId.remove(request.requestId);
    }
    broadcast({'type': 'cleared'});
    return stale.length;
  }

  HttpRequest? find(String requestId) => _byId[requestId];
}

/// The identity of one connected console.
class _Viewer {
  final String userId;
  final bool isAdmin;

  const _Viewer({required this.userId, required this.isAdmin});

  /// Admins see every exchange; everybody else sees only the traffic their own rules carried.
  bool canSee(String owner) => isAdmin || (owner.isNotEmpty && owner == userId);
}
