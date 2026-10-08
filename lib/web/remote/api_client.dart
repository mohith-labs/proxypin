import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:proxypin/web/web_environment.dart';

/// HTTP calls from the web UI to its ProxyPin server (same origin; the session cookie travels automatically).
class ApiClient {
  ApiClient._();

  static final http.Client _client = http.Client();

  /// Identifies this tab, so it can skip change notifications caused by its own writes.
  static final String clientId = List.generate(12, (_) => Random().nextInt(36).toRadixString(36)).join();

  static Map<String, String> get _headers => {'X-ProxyPin-Client': clientId};

  /// Fired when the server answers 401 (session expired); the app shows the login page again.
  static final StreamController<void> _unauthorized = StreamController.broadcast();

  static Stream<void> get onUnauthorized => _unauthorized.stream;

  static Uri uri(String path, [Map<String, String>? query]) =>
      Uri.base.resolve('${WebEnvironment.apiBase}/$path').replace(queryParameters: query);

  static Future<http.Response> get(String path, {Map<String, String>? query}) =>
      _check(_client.get(uri(path, query), headers: _headers));

  static Future<http.Response> send(String method, String path,
      {Map<String, String>? query, Object? json, List<int>? bytes}) {
    final request = http.Request(method, uri(path, query))..headers.addAll(_headers);
    if (json != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(json));
    } else if (bytes != null) {
      request.headers['Content-Type'] = 'application/octet-stream';
      request.bodyBytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    }
    return _check(_client.send(request).then(http.Response.fromStream));
  }

  static Future<Map<String, dynamic>> getJson(String path, {Map<String, String>? query}) async =>
      _json(await get(path, query: query));

  static Future<Map<String, dynamic>> postJson(String path, {Object? json, Map<String, String>? query}) async =>
      _json(await send('POST', path, query: query, json: json ?? const {}));

  static Future<http.Response> _check(Future<http.Response> future) async {
    final response = await future;
    if (response.statusCode == 401) _unauthorized.add(null);
    return response;
  }

  static Map<String, dynamic> _json(http.Response response) {
    final decoded = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode >= 400) {
      final message = decoded is Map ? decoded['error'] ?? response.reasonPhrase : response.reasonPhrase;
      throw ApiException(response.statusCode, message?.toString() ?? 'HTTP ${response.statusCode}');
    }
    return decoded is Map<String, dynamic> ? decoded : {'value': decoded};
  }
}

class ApiException implements Exception {
  final int status;
  final String message;

  ApiException(this.status, this.message);

  @override
  String toString() => message;
}
