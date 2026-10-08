import 'dart:convert';
import 'dart:math';

import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/server/server_environment.dart';

/// Optional login for the UI/API (enabled by PROXYPIN_PASSWORD). Browsers get an HttpOnly session cookie scoped
/// to the UI prefix, so it is never sent to reverse-proxied paths; scripts may use HTTP Basic auth instead.
class AdminAuth {
  static const String cookieName = 'proxypin_session';
  static const Duration sessionTtl = Duration(days: 7);

  final Map<String, DateTime> _sessions = {};
  final Random _random = Random.secure();

  bool get enabled => ServerEnvironment.authEnabled;

  bool isAuthenticated(HttpRequest request) {
    if (!enabled) return true;
    final token = _cookie(request, cookieName);
    if (token != null) {
      final expires = _sessions[token];
      if (expires != null && expires.isAfter(DateTime.now())) {
        _sessions[token] = DateTime.now().add(sessionTtl); // sliding expiry
        return true;
      }
      _sessions.remove(token);
    }

    final authorization = request.headers.get('Authorization');
    if (authorization != null && authorization.toLowerCase().startsWith('basic ')) {
      try {
        final decoded = utf8.decode(base64Decode(authorization.substring(6).trim()));
        final separator = decoded.indexOf(':');
        if (separator > 0) return verify(decoded.substring(0, separator), decoded.substring(separator + 1));
      } catch (_) {}
    }
    return false;
  }

  bool verify(String? username, String? password) {
    if (!enabled) return true;
    return _constantTimeEquals(username ?? '', ServerEnvironment.username) &
        _constantTimeEquals(password ?? '', ServerEnvironment.password ?? '');
  }

  /// Creates a session and returns the Set-Cookie header value.
  String login() {
    _sessions.removeWhere((_, expires) => expires.isBefore(DateTime.now()));
    final token = List.generate(32, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _sessions[token] = DateTime.now().add(sessionTtl);
    return '$cookieName=$token; Path=${ServerEnvironment.uiPrefix}; HttpOnly; SameSite=Strict; '
        'Max-Age=${sessionTtl.inSeconds}';
  }

  /// Ends the session and returns the Set-Cookie header value that clears the cookie.
  String logout(HttpRequest request) {
    final token = _cookie(request, cookieName);
    if (token != null) _sessions.remove(token);
    return '$cookieName=; Path=${ServerEnvironment.uiPrefix}; HttpOnly; SameSite=Strict; Max-Age=0';
  }

  static String? _cookie(HttpRequest request, String name) {
    for (final header in request.headers.getList('Cookie') ?? const <String>[]) {
      for (final part in header.split(';')) {
        final index = part.indexOf('=');
        if (index > 0 && part.substring(0, index).trim() == name) return part.substring(index + 1).trim();
      }
    }
    return null;
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a), y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < max(x.length, y.length); i++) {
      diff |= (i < x.length ? x[i] : 0) ^ (i < y.length ? y[i] : 0);
    }
    return diff == 0;
  }
}
