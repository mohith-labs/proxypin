import 'package:proxypin/network/channel/host_port.dart';

/// A reverse-proxy route: requests whose path starts with [path] are forwarded to [target].
///
/// With [stripPrefix] (the default) the matched prefix is removed before the remainder is appended to the
/// target's base path, like nginx `location /proxy/ { proxy_pass https://example.com/; }`:
///   `/proxy`            -> `https://example.com/`
///   `/proxy/users?id=1` -> `https://example.com/users?id=1`
/// Without it the full path is appended: `/proxy/users` -> `https://example.com/proxy/users`.
class ReverseProxyRule {
  bool enabled;
  String name;

  /// Path prefix matched on segment boundaries (`/api` matches `/api` and `/api/x`, not `/apix`). `/` matches all.
  String path;

  /// Absolute http(s) URL, optionally with a base path (`https://example.com/v2`).
  String target;

  bool stripPrefix;

  /// Forward the client's Host header instead of the target's (Reqable "Preserve Host in Header").
  bool preserveHost;

  /// Map `Location` headers and `Set-Cookie` domain/path that point at the target back onto the proxy path.
  bool rewriteResponse;

  ReverseProxyRule({
    this.enabled = true,
    this.name = '',
    required String path,
    required this.target,
    this.stripPrefix = true,
    this.preserveHost = false,
    this.rewriteResponse = true,
  }) : path = normalizePath(path);

  factory ReverseProxyRule.fromJson(Map<String, dynamic> json) {
    return ReverseProxyRule(
      enabled: json['enabled'] ?? true,
      name: json['name'] ?? '',
      path: json['path'] ?? '/',
      target: json['target'] ?? '',
      stripPrefix: json['stripPrefix'] ?? true,
      preserveHost: json['preserveHost'] ?? false,
      rewriteResponse: json['rewriteResponse'] ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'name': name,
        'path': path,
        'target': target,
        'stripPrefix': stripPrefix,
        'preserveHost': preserveHost,
        'rewriteResponse': rewriteResponse,
      };

  /// `"proxy/"` -> `"/proxy"`, `""` -> `"/"`.
  static String normalizePath(String path) {
    var value = path.trim();
    if (!value.startsWith('/')) value = '/$value';
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// Returns null when [target] is a usable http(s) URL, otherwise a short reason.
  static String? validateTarget(String target) {
    final uri = Uri.tryParse(target.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return 'Target must be an absolute URL, e.g. https://example.com';
    if (uri.scheme != 'http' && uri.scheme != 'https') return 'Target scheme must be http or https';
    if (uri.hasQuery || uri.hasFragment) return 'Target must not contain a query or fragment';
    return null;
  }

  Uri get targetUri => Uri.parse(target.trim());

  /// Base path of the target without a trailing slash (`https://x.com/` -> ``, `https://x.com/v2/` -> `/v2`).
  String get _targetBasePath {
    var base = targetUri.path;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  HostAndPort get targetHostAndPort {
    final uri = targetUri;
    return HostAndPort(uri.scheme == 'https' ? HostAndPort.httpsScheme : HostAndPort.httpScheme, uri.host, uri.port);
  }

  /// Value for the upstream Host header (port only when not the scheme default).
  String get targetHostHeader {
    final uri = targetUri;
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    return uri.port == defaultPort ? host : '$host:${uri.port}';
  }

  /// Whether this rule handles the (decoded-or-raw) request [requestPath] (path only, no query).
  bool matches(String requestPath) {
    if (path == '/') return true;
    return requestPath == path || requestPath.startsWith('$path/');
  }

  /// Maps the client's raw path+query onto the upstream origin-form URI.
  String upstreamUri(String pathAndQuery) {
    final queryIndex = pathAndQuery.indexOf('?');
    final requestPath = queryIndex < 0 ? pathAndQuery : pathAndQuery.substring(0, queryIndex);
    final query = queryIndex < 0 ? '' : pathAndQuery.substring(queryIndex);

    var remainder = requestPath;
    if (stripPrefix && path != '/') {
      remainder = requestPath.length > path.length ? requestPath.substring(path.length) : '';
    }
    var upstreamPath = _join(_targetBasePath, remainder);
    if (upstreamPath.isEmpty) upstreamPath = '/';
    return '$upstreamPath$query';
  }

  /// Inverse of [upstreamUri] for a path on the target (used for redirects/cookies). Null when the path is
  /// outside the target's base path and so cannot be reached through this rule.
  String? proxyPathFor(String upstreamPathAndQuery) {
    final queryIndex = upstreamPathAndQuery.indexOf('?');
    final upstreamPath = queryIndex < 0 ? upstreamPathAndQuery : upstreamPathAndQuery.substring(0, queryIndex);
    final query = queryIndex < 0 ? '' : upstreamPathAndQuery.substring(queryIndex);

    final base = _targetBasePath;
    String rest;
    if (base.isEmpty) {
      rest = upstreamPath;
    } else if (upstreamPath == base || upstreamPath.startsWith('$base/')) {
      rest = upstreamPath.substring(base.length);
    } else {
      return null;
    }

    String proxyPath;
    if (stripPrefix && path != '/') {
      proxyPath = _join(path, rest);
    } else {
      proxyPath = rest;
      if (!matches(proxyPath.isEmpty ? '/' : proxyPath)) return null;
    }
    if (proxyPath.isEmpty) proxyPath = '/';
    return '$proxyPath$query';
  }

  /// Whether [url] (absolute) points at this rule's target origin.
  bool isTargetOrigin(Uri url) {
    final target = targetUri;
    return url.scheme == target.scheme && url.host.toLowerCase() == target.host.toLowerCase() && url.port == target.port;
  }

  static String _join(String base, String rest) {
    if (rest.isEmpty) return base;
    if (base.endsWith('/') && rest.startsWith('/')) return base + rest.substring(1);
    if (!base.endsWith('/') && !rest.startsWith('/')) return '$base/$rest';
    return base + rest;
  }

  ReverseProxyRule copy() => ReverseProxyRule.fromJson(toJson());

  @override
  String toString() => 'ReverseProxyRule{$path -> $target, strip: $stripPrefix, enabled: $enabled}';
}
