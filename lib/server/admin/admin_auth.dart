import 'dart:math';

import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/server/auth/auth_store.dart';
import 'package:proxypin/server/server_environment.dart';

/// A signed-in browser session, bound to the user that created it.
class AdminSession {
  final String userId;
  DateTime expires;

  AdminSession(this.userId, this.expires);
}

/// Google sign-in sessions for the UI/API. Browsers get an HttpOnly cookie scoped to the UI prefix, so it is
/// never sent to reverse-proxied paths.
///
/// A session only names the user; the account's current state is re-read from [AuthStore] on every request,
/// so blocking a user takes effect immediately instead of when their cookie expires.
class AdminAuth {
  static const String cookieName = 'proxypin_session';
  static const Duration sessionTtl = Duration(days: 7);

  final Map<String, AdminSession> _sessions = {};
  final Random _random = Random.secure();
  final AuthStore store;

  AdminAuth(this.store);

  /// The console always requires a login now; sign-in is Google-only.
  bool get enabled => true;

  /// The user behind this request, or null when it is not signed in (or no longer allowed).
  AppUser? currentUser(HttpRequest request) {
    final token = _cookie(request, cookieName);
    if (token == null) return null;
    final session = _sessions[token];
    if (session == null) return null;
    if (session.expires.isBefore(DateTime.now())) {
      _sessions.remove(token);
      return null;
    }
    final user = store.byId(session.userId);
    if (user == null || user.status != UserStatus.approved) return null; // blocked/removed: cookie stops working
    session.expires = DateTime.now().add(sessionTtl); // sliding expiry
    return user;
  }

  bool isAuthenticated(HttpRequest request) => currentUser(request) != null;

  bool isAdmin(HttpRequest request) => currentUser(request)?.isAdmin == true;

  /// Creates a session for [user] and returns the Set-Cookie header value.
  String login(AppUser user) {
    _sessions.removeWhere((_, session) => session.expires.isBefore(DateTime.now()));
    final token = List.generate(32, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _sessions[token] = AdminSession(user.id, DateTime.now().add(sessionTtl));
    return '$cookieName=$token; Path=${ServerEnvironment.uiPrefix}; HttpOnly; SameSite=Lax; '
        'Max-Age=${sessionTtl.inSeconds}';
  }

  /// Ends the session and returns the Set-Cookie header value that clears the cookie.
  String logout(HttpRequest request) {
    final token = _cookie(request, cookieName);
    if (token != null) _sessions.remove(token);
    return '$cookieName=; Path=${ServerEnvironment.uiPrefix}; HttpOnly; SameSite=Lax; Max-Age=0';
  }

  /// Drops every session of a user that was just blocked or deleted.
  void revokeSessionsOf(String userId) => _sessions.removeWhere((_, session) => session.userId == userId);

  static String? _cookie(HttpRequest request, String name) {
    for (final header in request.headers.getList('Cookie') ?? const <String>[]) {
      for (final part in header.split(';')) {
        final index = part.indexOf('=');
        if (index > 0 && part.substring(0, index).trim() == name) return part.substring(index + 1).trim();
      }
    }
    return null;
  }
}
