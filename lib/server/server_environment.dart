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
/// | `PROXYPIN_USER` / `PROXYPIN_PASSWORD` | admin / unset | UI login; auth is off while the password is unset |
/// | `PROXYPIN_BREAKPOINT_TIMEOUT` | 600 | seconds a breakpoint may stay paused |
/// | `PROXYPIN_HISTORY_LIMIT` | 2000 | captured requests kept in memory for the UI |
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

  static String get username => _value('PROXYPIN_USER') ?? 'admin';

  static String? get password => _value('PROXYPIN_PASSWORD');

  static bool get authEnabled => password != null;

  static Duration get breakpointTimeout =>
      Duration(seconds: int.tryParse(_value('PROXYPIN_BREAKPOINT_TIMEOUT') ?? '') ?? 600);

  static int get historyLimit => int.tryParse(_value('PROXYPIN_HISTORY_LIMIT') ?? '') ?? 2000;
}
