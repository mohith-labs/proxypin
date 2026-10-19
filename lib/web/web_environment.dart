/// What the web UI knows about the ProxyPin server that serves it (filled from `/__proxypin/api/info`).
class WebEnvironment {
  WebEnvironment._();

  /// The UI and API live below this path on the same origin as the reverse proxy.
  static const String uiPrefix = '/__proxypin';

  static String get apiBase => '$uiPrefix/api';

  /// The server's data directory; file paths used by the managers are server paths below it.
  static String dataDir = '/data';

  static int port = 8080;
  static String version = '';
  static bool authRequired = false;
  static int? internalProxyPort;

  /// The signed-in account (`/__proxypin/api/session` → `user`).
  static Map<String, dynamic>? currentUser;

  static String? get userEmail => currentUser?['email']?.toString();

  static String? get userName {
    final name = currentUser?['name']?.toString();
    return name == null || name.isEmpty ? userEmail : name;
  }

  static String? get userPicture {
    final picture = currentUser?['picture']?.toString();
    return picture == null || picture.isEmpty ? null : picture;
  }

  /// Whether this account administers the console (PROXYPIN_ADMIN_EMAIL on the server).
  static bool isAdmin = false;

  static void apply(Map<String, dynamic> info) {
    dataDir = info['dataDir'] ?? dataDir;
    port = info['port'] ?? port;
    version = info['version'] ?? version;
    authRequired = info['authRequired'] == true;
    internalProxyPort = info['internalProxyPort'];
    final user = info['user'];
    if (user is Map) {
      currentUser = Map<String, dynamic>.from(user);
      isAdmin = currentUser?['isAdmin'] == true;
    }
  }

  /// Origin the browser used, e.g. `http://localhost:8080` (what clients point at for the reverse proxy).
  static String get origin => Uri.base.origin;
}
