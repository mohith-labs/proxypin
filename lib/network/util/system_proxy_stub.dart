import 'package:proxypin/network/channel/host_port.dart';

/// Same values as `ProxyTypes` from package:proxy_manager (which needs Flutter).
enum ProxyTypes { http, https, socks }

/// No system proxy on the headless server / in the browser.
class SystemProxy {
  static String get proxyPassDomains => '';

  static Future<ProxyInfo?> getSystemProxy(ProxyTypes types) async => null;

  static Future<void> setSystemProxy(int port, bool sslSetting, String proxyPassDomains) async {}

  static void setSslProxyEnable(bool proxyEnable, port) {}

  static Future<void> setSystemProxyEnable(int port, bool enable, bool sslSetting,
      {required String passDomains}) async {}

  static Future<void> setProxyPassDomains(String proxyPassDomains) async {}
}
