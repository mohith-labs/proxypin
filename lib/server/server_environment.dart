import 'dart:io';

/// Settings of the headless ProxyPin server, read once from the environment.
///
/// | Variable | Default | Meaning |
/// |---|---|---|
/// | `PORT` / `PROXYPIN_PORT` | 8080 | listen port for the UI (`/__proxypin/`) and the reverse proxy |
/// | `PROXYPIN_BIND` | 0.0.0.0 | listen address |
/// | `PROXYPIN_DATA_DIR` | `<cwd>/data` | rules, scripts, history, favorites, certificates |
/// | `PROXYPIN_HOME` | dir with `assets/` next to the executable, else cwd | install root (`assets/`, `web/`, `server/js/`) |
/// | `PROXYPIN_WEB_DIR` | `<home>/build/web`, else `<home>/web` | compiled Flutter web UI |
/// | `PROXYPIN_NODE` | `node` | Node.js binary used to run scripts |
/// | `PROXYPIN_SCRIPT_WORKER` | `<home>/server/js/script_worker.mjs` | script worker |
/// | `PROXYPIN_GOOGLE_CLIENT_ID` / `PROXYPIN_GOOGLE_CLIENT_SECRET` | unset | Google OAuth client; sign-in is disabled while unset |
/// | `PROXYPIN_ADMIN_EMAIL` | unset | comma-separated admin addresses (console settings, user approval) |
/// | `PROXYPIN_PUBLIC_URL` | derived from the request | external base URL, used to build the OAuth callback |
/// | `PROXYPIN_BREAKPOINT_TIMEOUT` | 600 | seconds a breakpoint may stay paused |
/// | `PROXYPIN_HISTORY_LIMIT` | 2000 | captured requests kept in memory for the UI |
/// | `PROXYPIN_TEST_LOGIN` | unset | `1` opens `api/test/login` (sessions without Google) for end-to-end tests; loopback only |
class ServerEnvironment {
  ServerEnvironment._();

  /// Every UI/API path lives below this prefix; everything else is reverse-proxy traffic.
  static const String uiPrefix = '/__proxypin';

  static Map<String, String> get _env => Platform.environment;

  static String? _value(String name) {
    final value = _env[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static int get port => int.tryParse(_value('PROXYPIN_PORT') ?? _value('PORT') ?? '') ?? 8080;

  static String get bindAddress => _value('PROXYPIN_BIND') ?? '0.0.0.0';

  static String? _dataDir;

  static String get dataDir {
    if (_dataDir != null) return _dataDir!;
    final dir = Directory(_value('PROXYPIN_DATA_DIR') ?? '${Directory.current.path}${Platform.pathSeparator}data');
    dir.createSync(recursive: true);
    return _dataDir = dir.absolute.path;
  }

  /// Overrides the data directory (tests).
  static set dataDir(String path) => _dataDir = path;

  static String? _home;

  static String get home {
    if (_home != null) return _home!;
    final configured = _value('PROXYPIN_HOME');
    if (configured != null) return _home = configured;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (Directory('$exeDir/assets').existsSync()) return _home = exeDir;
    return _home = Directory.current.path;
  }

  static set home(String path) => _home = path;

  /// Absolute path of a bundled asset such as `assets/certs/ca.crt`.
  static String assetPath(String asset) => '$home/$asset';

  static String get webDir {
    final configured = _value('PROXYPIN_WEB_DIR');
    if (configured != null) return configured;
    // a source checkout has the web/ template too; prefer the compiled build/web there
    if (File('$home/build/web/index.html').existsSync()) return '$home/build/web';
    return '$home/web';
  }

  static String get nodeBinary => _value('PROXYPIN_NODE') ?? 'node';

  static String get scriptWorker => _value('PROXYPIN_SCRIPT_WORKER') ?? '$home/server/js/script_worker.mjs';

  // ----------------------------------------------------------------------------------- Google sign-in

  static String? get googleClientId => _value('PROXYPIN_GOOGLE_CLIENT_ID');

  static String? get googleClientSecret => _value('PROXYPIN_GOOGLE_CLIENT_SECRET');

  static bool get googleConfigured => googleClientId != null && googleClientSecret != null;

  /// External base URL of the console (`https://proxypin.example.com`), without a trailing slash.
  /// When unset, the callback URL is derived from the request's Host/X-Forwarded-* headers.
  static String? get publicUrl {
    final value = _value('PROXYPIN_PUBLIC_URL');
    if (value == null) return null;
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  /// Accounts that administer the console. Supports several addresses, comma or space separated.
  static List<String> get adminEmails =>
      (_value('PROXYPIN_ADMIN_EMAIL') ?? '').split(RegExp(r'[,\s]+')).map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();

  static bool isAdminEmail(String? email) =>
      email != null && email.isNotEmpty && adminEmails.contains(email.toLowerCase());

  /// Per-user data directory (`<dataDir>/users/<key>`), where that user's favorites and history live.
  static String userDataDir(String storageKey) =>
      '$dataDir${Platform.pathSeparator}users${Platform.pathSeparator}$storageKey';

  /// A config file shared by everybody (the proxy engine's own state, e.g. `reverse_proxy.json`).
  static String sharedConfigPath(String fileName) => '$dataDir${Platform.pathSeparator}$fileName';

  static Duration get breakpointTimeout =>
      Duration(seconds: int.tryParse(_value('PROXYPIN_BREAKPOINT_TIMEOUT') ?? '') ?? 600);

  static int get historyLimit => int.tryParse(_value('PROXYPIN_HISTORY_LIMIT') ?? '') ?? 2000;

  /// Whether the listen address only accepts connections from this machine.
  static bool get boundToLoopback {
    final address = bindAddress;
    return address == '127.0.0.1' || address == '::1' || address == 'localhost';
  }

  /// Opens `api/test/login`, which mints a session without Google, for end-to-end tests.
  ///
  /// It is an authentication bypass, so it is off unless the variable is explicitly set to `1`/`true`, and the
  /// server refuses to start with it on unless it is also bound to loopback.
  static bool get testLoginEnabled {
    final value = _value('PROXYPIN_TEST_LOGIN')?.toLowerCase();
    return value == '1' || value == 'true';
  }
}
