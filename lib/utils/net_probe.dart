import 'net_probe_native.dart' if (dart.library.js_interop) 'net_probe_web.dart' as impl;

/// TCP reachability checks (e.g. of an external proxy). The web UI asks the ProxyPin server, since that is
/// where the proxied traffic comes from (and browsers cannot open raw sockets).
class NetProbe {
  NetProbe._();

  static Future<bool> reachable(String host, int port, {Duration timeout = const Duration(seconds: 1)}) =>
      impl.reachable(host, port, timeout);
}
