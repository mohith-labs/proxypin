import 'dart:convert';

import 'package:proxypin/network/bin/listener.dart';
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

  final Set<void Function(String json)> _subscribers = {};

  void subscribe(void Function(String json) subscriber) => _subscribers.add(subscriber);

  void unsubscribe(void Function(String json) subscriber) => _subscribers.remove(subscriber);

  int get subscriberCount => _subscribers.length;

  void broadcast(Map<String, dynamic> event) {
    if (_subscribers.isEmpty) return;
    final json = jsonEncode(event);
    for (final subscriber in List.of(_subscribers)) {
      subscriber(json);
    }
  }

  @override
  void onRequest(Channel? channel, HttpRequest request) {
    if (!capturing) return;
    _upsert(request);
    broadcast({'type': 'request', 'request': _request(request)});
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {
    if (!capturing) return;
    final request = response.request;
    if (request != null && !_byId.containsKey(request.requestId)) _upsert(request);
    broadcast({'type': 'response', 'response': _response(response, includeMessages: false)});
  }

  @override
  void onMessage(Channel? channel, HttpMessage message, WebSocketFrame frame) {
    if (!capturing) return;
    final bool fromRequest = message is HttpRequest;
    final requestId = message is HttpResponse ? (message.request?.requestId ?? message.requestId) : message.requestId;
    broadcast({
      'type': 'frame',
      'requestId': requestId,
      'target': fromRequest ? 'request' : 'response',
      'frame': Wire.frame(frame),
    });
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

  /// Session backlog for a newly connected browser.
  List<Map<String, dynamic>> snapshot() => container
      .map((request) => {
            'request': _request(request),
            if (request.response != null) 'response': _response(request.response!),
          })
      .toList();

  static Map<String, dynamic> _request(HttpRequest request) =>
      Wire.request(request, decodedBody: ContentDecoding.decodedBody(request));

  static Map<String, dynamic> _response(HttpResponse response, {bool includeMessages = true}) =>
      Wire.response(response, includeMessages: includeMessages, decodedBody: ContentDecoding.decodedBody(response));

  void clear() {
    container.clear();
    _byId.clear();
    broadcast({'type': 'cleared'});
  }

  HttpRequest? find(String requestId) => _byId[requestId];
}
