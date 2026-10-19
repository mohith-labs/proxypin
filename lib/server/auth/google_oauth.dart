import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/server/server_environment.dart';

/// The Google profile behind a successful authorization code exchange.
class GoogleProfile {
  final String subject;
  final String email;
  final String name;
  final String picture;
  final bool emailVerified;

  GoogleProfile({
    required this.subject,
    required this.email,
    required this.name,
    required this.picture,
    required this.emailVerified,
  });
}

class OAuthException implements Exception {
  final String message;

  OAuthException(this.message);

  @override
  String toString() => message;
}

/// Google sign-in (OAuth 2.0 authorization code flow) for the web console.
///
/// The browser never sees the client secret: it is redirected to Google, comes back with a one-time
/// code, and the server exchanges that code over its own HTTPS connection.
class GoogleOAuth {
  static const String _authorizeEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const String _tokenEndpoint = 'https://oauth2.googleapis.com/token';

  final Random _random = Random.secure();

  /// Pending `state` values, so a callback that we did not start is rejected (CSRF).
  final Map<String, PendingLogin> _pending = {};

  static const Duration _stateTtl = Duration(minutes: 10);

  bool get configured => ServerEnvironment.googleConfigured;

  /// Starts a login: returns the Google URL to redirect the browser to.
  String authorizationUrl({required String redirectUri, String? returnTo}) {
    _pending.removeWhere((_, value) => value.expired);
    final state = _token();
    _pending[state] = PendingLogin(DateTime.now().add(_stateTtl), returnTo);
    final uri = Uri.parse(_authorizeEndpoint).replace(queryParameters: {
      'client_id': ServerEnvironment.googleClientId!,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': 'openid email profile',
      'state': state,
      'prompt': 'select_account',
    });
    return uri.toString();
  }

  /// Consumes a `state` from the callback; returns the stored "return to" path when it is valid.
  PendingLogin? takeState(String? state) {
    if (state == null) return null;
    final pending = _pending.remove(state);
    if (pending == null || pending.expired) return null;
    return pending;
  }

  /// Exchanges the authorization code for tokens and reads the profile from the ID token.
  Future<GoogleProfile> exchange(String code, String redirectUri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(Uri.parse(_tokenEndpoint));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded');
      final form = {
        'code': code,
        'client_id': ServerEnvironment.googleClientId!,
        'client_secret': ServerEnvironment.googleClientSecret!,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
      };
      request.write(form.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'));
      final response = await request.close().timeout(const Duration(seconds: 20));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        logger.w('google token exchange failed: ${response.statusCode} $body');
        throw OAuthException('Google rejected the sign-in (HTTP ${response.statusCode}).');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final idToken = json['id_token']?.toString();
      if (idToken == null) throw OAuthException('Google did not return an id_token.');
      return _profileFromIdToken(idToken);
    } on TimeoutException {
      throw OAuthException('Google did not answer in time.');
    } on SocketException catch (e) {
      throw OAuthException('Cannot reach Google: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// Reads the claims of the ID token.
  ///
  /// The token arrived over our own TLS connection to Google's token endpoint in direct response to a
  /// code we issued, so the transport authenticates it; we still check audience, issuer and expiry.
  GoogleProfile _profileFromIdToken(String idToken) {
    final parts = idToken.split('.');
    if (parts.length != 3) throw OAuthException('Malformed id_token.');
    final Map<String, dynamic> claims;
    try {
      claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
    } catch (_) {
      throw OAuthException('Malformed id_token payload.');
    }

    final audience = claims['aud'];
    if (audience != ServerEnvironment.googleClientId) throw OAuthException('id_token was issued for another client.');

    final issuer = claims['iss']?.toString();
    if (issuer != 'accounts.google.com' && issuer != 'https://accounts.google.com') {
      throw OAuthException('Unexpected id_token issuer.');
    }

    final exp = claims['exp'];
    if (exp is int && DateTime.fromMillisecondsSinceEpoch(exp * 1000).isBefore(DateTime.now())) {
      throw OAuthException('id_token has expired.');
    }

    final subject = claims['sub']?.toString() ?? '';
    final email = claims['email']?.toString() ?? '';
    if (subject.isEmpty || email.isEmpty) throw OAuthException('Google did not return an email address.');

    final verified = claims['email_verified'] == true || claims['email_verified'] == 'true';
    if (!verified) throw OAuthException('This Google account has no verified email address.');

    return GoogleProfile(
      subject: subject,
      email: email,
      name: claims['name']?.toString() ?? '',
      picture: claims['picture']?.toString() ?? '',
      emailVerified: verified,
    );
  }

  String _token() => List.generate(24, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// A sign-in that was started and is waiting for Google to redirect back.
class PendingLogin {
  final DateTime expires;
  final String? returnTo;

  PendingLogin(this.expires, this.returnTo);

  bool get expired => expires.isBefore(DateTime.now());
}
