import 'dart:convert';

import 'package:proxypin/network/http/http.dart';

/// Small helpers for building admin (UI/API) responses on the raw ProxyPin pipeline.
class AdminHttp {
  AdminHttp._();

  static HttpResponse bytes(int status, List<int> body, {String contentType = 'application/octet-stream'}) {
    return HttpResponse(HttpStatus.newStatus(status, _reason(status)))
      ..headers.set('Content-Type', contentType)
      ..headers.set('Cache-Control', 'no-store')
      ..headers.contentLength = body.length
      ..body = body;
  }

  static HttpResponse json(Object? data, {int status = 200}) =>
      bytes(status, utf8.encode(jsonEncode(data)), contentType: 'application/json; charset=utf-8');

  static HttpResponse error(int status, String message) => json({'error': message}, status: status);

  static HttpResponse text(int status, String message) =>
      bytes(status, utf8.encode(message), contentType: 'text/plain; charset=utf-8');

  static HttpResponse redirect(String location) {
    return HttpResponse(HttpStatus(302, 'Found'))
      ..headers.set('Location', location)
      ..headers.contentLength = 0
      ..body = const [];
  }

  static Map<String, dynamic> jsonBody(HttpRequest request) {
    final body = request.body;
    if (body == null || body.isEmpty) return {};
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('expected a JSON object');
  }

  static String _reason(int status) => switch (status) {
        200 => 'OK',
        204 => 'No Content',
        304 => 'Not Modified',
        400 => 'Bad Request',
        401 => 'Unauthorized',
        403 => 'Forbidden',
        404 => 'Not Found',
        405 => 'Method Not Allowed',
        409 => 'Conflict',
        413 => 'Payload Too Large',
        500 => 'Internal Server Error',
        502 => 'Bad Gateway',
        503 => 'Service Unavailable',
        504 => 'Gateway Timeout',
        _ => '',
      };
}
