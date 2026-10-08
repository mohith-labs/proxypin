import 'dart:convert';
import 'dart:typed_data';

import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_headers.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/network/util/process_info.dart';

/// JSON wire format shared by the headless server and the web UI.
///
/// Unlike [HttpRequest.toJson] (used for windows, favorites and HAR) this keeps everything the UI shows:
/// target host/port, client and server addresses, process info, attributes, timings, the request id that
/// links a response to its request, and bodies as base64.
class Wire {
  Wire._();

  /// [decodedBody]: the body without its Content-Encoding, for encodings the browser cannot decode itself
  /// (see [HttpMessage.decodedBody]).
  static Map<String, dynamic> request(HttpRequest request, {bool includeMessages = true, List<int>? decodedBody}) => {
        'id': request.requestId,
        'method': request.method.name,
        'uri': request.uri,
        'url': request.requestUrl,
        'protocol': request.protocolVersion,
        if (request.hostAndPort != null) 'hostAndPort': hostAndPort(request.hostAndPort!),
        'headers': request.headers.toJson(),
        if (request.body != null) 'body': base64Encode(request.body!),
        if (decodedBody != null) 'decodedBody': base64Encode(decodedBody),
        'requestTime': request.requestTime.millisecondsSinceEpoch,
        if (request.packageSize != null) 'packageSize': request.packageSize,
        if (request.remoteHost != null) 'remoteHost': request.remoteHost,
        if (request.remotePort != null) 'remotePort': request.remotePort,
        if (request.streamId != null) 'streamId': request.streamId,
        if (request.processInfo != null) 'processInfo': request.processInfo!.toJson(),
        'attributes': _attributes(request.attributes),
        if (includeMessages) 'messages': request.messages.map((e) => e.toJson()).toList(),
      };

  static HttpRequest requestFrom(Map<String, dynamic> json) {
    final request = HttpRequest(HttpMethod.valueOf(json['method']), json['uri'] ?? json['url'] ?? '/',
        protocolVersion: json['protocol'] ?? HttpMessage.http1Version);
    request.requestId = json['id'] ?? request.requestId;
    if (json['hostAndPort'] is Map) request.hostAndPort = hostAndPortFrom(Map<String, dynamic>.from(json['hostAndPort']));
    if (json['headers'] is Map) request.headers.addAll(HttpHeaders.fromJson(Map<String, dynamic>.from(json['headers'])));
    request.body = _body(json['body']);
    request.decodedBody = _body(json['decodedBody']);
    if (json['requestTime'] is int) request.requestTime = DateTime.fromMillisecondsSinceEpoch(json['requestTime']);
    request.packageSize = json['packageSize'];
    request.remoteHost = json['remoteHost'];
    request.remotePort = json['remotePort'];
    request.streamId = json['streamId'];
    if (json['processInfo'] is Map) {
      request.processInfo = ProcessInfo.fromJson(Map<String, dynamic>.from(json['processInfo']));
    }
    if (json['attributes'] is Map) request.attributes.addAll(Map<String, dynamic>.from(json['attributes']));
    request.messages = _frames(json['messages']);
    return request;
  }

  static Map<String, dynamic> response(HttpResponse response, {bool includeMessages = true, List<int>? decodedBody}) =>
      {
        'requestId': response.request?.requestId ?? response.requestId,
        'status': response.status.code,
        'reason': response.status.reasonPhrase,
        'protocol': response.protocolVersion,
        if (response.requestUrl != null) 'requestUrl': response.requestUrl,
        'headers': response.headers.toJson(),
        if (response.body != null) 'body': base64Encode(response.body!),
        if (decodedBody != null) 'decodedBody': base64Encode(decodedBody),
        'responseTime': response.responseTime.millisecondsSinceEpoch,
        if (response.packageSize != null) 'packageSize': response.packageSize,
        if (response.remoteHost != null) 'remoteHost': response.remoteHost,
        if (response.remotePort != null) 'remotePort': response.remotePort,
        if (response.streamId != null) 'streamId': response.streamId,
        if (includeMessages) 'messages': response.messages.map((e) => e.toJson()).toList(),
      };

  static HttpResponse responseFrom(Map<String, dynamic> json, {HttpRequest? request}) {
    // fromJson is the only way to set the private requestUrl fallback; the rest is filled in below
    final response = HttpResponse.fromJson({
      'status': {'code': json['status'] ?? 0, 'reasonPhrase': json['reason'] ?? ''},
      'protocolVersion': json['protocol'] ?? HttpMessage.http1Version,
      'headers': json['headers'] ?? const <String, dynamic>{},
      'requestUrl': json['requestUrl'],
      'responseTime': json['responseTime'],
      'packageSize': json['packageSize'],
    });
    response.body = _body(json['body']);
    response.decodedBody = _body(json['decodedBody']);
    response.requestId = json['requestId'] ?? response.requestId;
    response.remoteHost = json['remoteHost'];
    response.remotePort = json['remotePort'];
    response.streamId = json['streamId'];
    response.messages = _frames(json['messages']);
    if (request != null) {
      response.request = request;
      request.response = response;
    }
    return response;
  }

  static Map<String, dynamic> frame(WebSocketFrame frame) => frame.toJson();

  static WebSocketFrame frameFrom(Map<String, dynamic> json) => WebSocketFrame.fromJson(json);

  static Map<String, dynamic> hostAndPort(HostAndPort hostAndPort) =>
      {'scheme': hostAndPort.scheme, 'host': hostAndPort.host, 'port': hostAndPort.port};

  static HostAndPort hostAndPortFrom(Map<String, dynamic> json) =>
      HostAndPort(json['scheme'] ?? HostAndPort.httpScheme, json['host'] ?? '', json['port'] ?? 80);

  /// Only JSON-safe attributes travel; keys starting with `_` are engine-private (caches, live objects).
  static Map<String, dynamic> _attributes(Map<String, dynamic> attributes) {
    final result = <String, dynamic>{};
    attributes.forEach((key, value) {
      if (key.startsWith('_') || value == null) return;
      try {
        jsonEncode(value);
        result[key] = value;
      } catch (_) {}
    });
    return result;
  }

  static List<int>? _body(dynamic value) => value is String ? Uint8List.fromList(base64Decode(value)) : null;

  static List<WebSocketFrame> _frames(dynamic value) {
    if (value is! List) return [];
    return value.whereType<Map>().map((e) => WebSocketFrame.fromJson(Map<String, dynamic>.from(e))).toList();
  }
}
