import 'dart:convert';

import 'package:proxypin/network/components/request_breakpoint.dart';
import 'package:proxypin/network/http/http.dart';

import 'capture/capture_hub.dart';
import 'capture/content_decoding.dart';

/// Shows breakpoint hits in every connected browser and resumes them from whichever one answers first.
/// Hits survive browser reloads: a newly connected UI receives the pending ones.
class BreakpointBroker {
  final CaptureHub hub;
  final Map<String, BreakpointHit> _pending = {};

  BreakpointBroker(this.hub) {
    RequestBreakpointInterceptor.presenter = _present;
    RequestBreakpointInterceptor.onResolved = _resolved;
  }

  static String _key(String requestId, bool isResponse) => '$requestId:${isResponse ? 'response' : 'request'}';

  /// Same payload as the desktop 'BreakpointExecutor' window, so the web UI can open that window as is.
  /// Brotli/zstd bodies also come decoded: the editor shows (and resumes with) the body text.
  static Map<String, dynamic> event(BreakpointHit hit) {
    final args = hit.toWindowArgs();
    _attachDecoded(args['request'], hit.request);
    if (hit.response != null) _attachDecoded(args['response'], hit.response!);
    return {
      'type': 'breakpoint',
      'title': hit.isResponse ? 'Breakpoint - Response' : 'Breakpoint - Request',
      'args': args,
    };
  }

  static void _attachDecoded(dynamic json, HttpMessage message) {
    final decoded = ContentDecoding.decodedBody(message);
    if (json is Map && decoded != null) json['decodedBody'] = base64Encode(decoded);
  }

  List<Map<String, dynamic>> get pendingEvents => _pending.values.map(event).toList();

  void _present(BreakpointHit hit) {
    _pending[_key(hit.requestId, hit.isResponse)] = hit;
    hub.broadcast(event(hit));
  }

  void _resolved(BreakpointHit hit) {
    _pending.remove(_key(hit.requestId, hit.isResponse));
    hub.broadcast({'type': 'breakpointResolved', 'requestId': hit.requestId, 'isResponse': hit.isResponse});
  }

  /// [message] is the edited `HttpRequest.toJson()` / `HttpResponse.toJson()`, or null to abort.
  bool resume(String? requestId, String phase, dynamic message) {
    if (requestId == null) return false;
    final isResponse = phase == 'response';
    if (!_pending.containsKey(_key(requestId, isResponse))) return false;

    final json = message is Map ? Map<String, dynamic>.from(message) : null;
    if (isResponse) {
      final response = json == null ? null : (HttpResponse.fromJson(json)..requestId = requestId);
      RequestBreakpointInterceptor.instance.resumeResponse(requestId, response);
    } else {
      RequestBreakpointInterceptor.instance.resumeRequest(requestId, json == null ? null : HttpRequest.fromJson(json));
    }
    return true;
  }
}
