import 'package:proxypin/network/components/interceptor.dart';
import 'package:proxypin/network/http/http.dart';

import 'reverse_proxy_handler.dart';
import 'reverse_proxy_rule.dart';

/// Maps redirects and cookies of a reverse-proxied response back onto the proxy path, so a browser that talks to
/// `http://host:8080/proxy` keeps going through the proxy (like nginx `proxy_redirect` + `proxy_cookie_*`).
///
/// Runs last so scripts and rewrite rules see the upstream response, while the capture list shows what the
/// client actually received.
class ReverseProxyResponseInterceptor extends Interceptor {
  @override
  int get priority => 5000;

  @override
  Future<HttpResponse?> onResponse(HttpRequest request, HttpResponse response) async {
    final rule = request.attributes[ReverseProxyChannelHandler.ruleAttribute];
    if (rule is! ReverseProxyRule || !rule.rewriteResponse) return response;

    for (final name in const ['Location', 'Content-Location']) {
      final value = response.headers.get(name);
      if (value == null) continue;
      final mapped = mapUrl(rule, value);
      if (mapped != null && mapped != value) response.headers.set(name, mapped);
    }

    final cookies = response.headers.getList('Set-Cookie');
    if (cookies != null && cookies.isNotEmpty) {
      final rewritten = cookies.map((cookie) => rewriteCookie(rule, cookie)).toList();
      response.headers.remove('Set-Cookie');
      for (final cookie in rewritten) {
        response.headers.add('Set-Cookie', cookie);
      }
    }
    return response;
  }

  /// `https://target/x?y` or `/x?y` (relative to the target) -> `/proxy/x?y`; anything else stays as is.
  static String? mapUrl(ReverseProxyRule rule, String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('/') && !trimmed.startsWith('//')) {
      return rule.proxyPathFor(trimmed);
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || !rule.isTargetOrigin(uri)) return null;
    final pathAndQuery = '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    final mapped = rule.proxyPathFor(pathAndQuery);
    if (mapped == null) return null;
    return uri.hasFragment ? '$mapped#${uri.fragment}' : mapped;
  }

  /// Drops `Domain=` (the browser talks to the proxy host) and maps `Path=` onto the proxy prefix.
  static String rewriteCookie(ReverseProxyRule rule, String cookie) {
    final parts = cookie.split(';');
    final result = <String>[parts.first];
    for (final part in parts.skip(1)) {
      final attribute = part.trim();
      final lower = attribute.toLowerCase();
      if (lower.startsWith('domain=')) continue;
      if (lower.startsWith('path=')) {
        final path = attribute.substring(5).trim();
        var mapped = path.startsWith('/') ? rule.proxyPathFor(path) : null;
        // "/proxy/" would not path-match "/proxy" itself (RFC 6265 5.1.4)
        if (mapped != null && mapped.length > 1 && mapped.endsWith('/')) mapped = mapped.substring(0, mapped.length - 1);
        result.add(' Path=${mapped ?? path}');
        continue;
      }
      result.add(part);
    }
    return result.join(';');
  }
}
