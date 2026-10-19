import 'dart:async';
import 'dart:io';

import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/network/components/hosts.dart';
import 'package:proxypin/network/components/interceptor.dart';
import 'package:proxypin/network/components/manager/environment_manager.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/components/network_condition.dart';
import 'package:proxypin/network/components/report_server_interceptor.dart';
import 'package:proxypin/network/components/request_block.dart';
import 'package:proxypin/network/components/request_breakpoint.dart';
import 'package:proxypin/network/components/request_map.dart';
import 'package:proxypin/network/components/request_rewrite.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_handler.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_interceptor.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_manager.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_server.dart';
import 'package:proxypin/network/components/script.dart';
import 'package:proxypin/network/handle/http_proxy_handle.dart';
import 'package:proxypin/network/http/codec.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/utils/listenable_list.dart';

import 'admin/admin_auth.dart';
import 'admin/admin_handler.dart';
import 'auth/auth_store.dart';
import 'auth/google_oauth.dart';
import 'breakpoint_broker.dart';
import 'capture/capture_hub.dart';
import 'config_reloader.dart';
import 'server_environment.dart';
import 'server_interceptors.dart';

/// Headless ProxyPin for Docker: one listener serves the web UI below `/__proxypin/` and reverse-proxies
/// every other path according to the configured rules, through the regular ProxyPin interceptor pipeline.
class ProxyPinWebServer {
  late final Configuration configuration;
  late final CaptureHub hub;
  late final BreakpointBroker breakpoints;
  late final ConfigReloader reloader;
  late final List<Interceptor> interceptors;
  late final AuthStore authStore;
  late final AdminAuth auth;
  final GoogleOAuth oauth = GoogleOAuth();
  final DateTime startedAt = DateTime.now();

  ReverseProxyServer? _frontDoor;
  Server? _internalProxy;
  Configuration? _internalConfiguration;

  /// One recorder per user: "save session" writes into that account's own directory.
  final Map<String, HistoryTask> _historyTasks = {};
  int? internalProxyPort;

  Future<void> start() async {
    authStore = await AuthStore.instance;
    auth = AdminAuth(authStore);
    configuration = await Configuration.instance;
    hub = CaptureHub(limit: ServerEnvironment.historyLimit);
    breakpoints = BreakpointBroker(hub);
    RequestBreakpointInterceptor.pauseTimeout = ServerEnvironment.breakpointTimeout;
    reloader = ConfigReloader(broadcast: hub.broadcast, onConfiguration: _applyConfiguration);

    await _loadManagers();
    ScriptManager.registerLogHandler(LogHandler(
        channelId: 'web', handle: (log) => hub.broadcast({'type': 'scriptLog', 'log': log.toJson()})));

    interceptors = [
      Hosts(),
      RequestMapInterceptor.instance,
      RequestRewriteInterceptor.instance,
      ScriptInterceptor(),
      RequestBlockInterceptor(),
      RequestBreakpointInterceptor.instance,
      NetworkConditionInterceptor.instance,
      ReportServerInterceptor(),
      ReverseProxyResponseInterceptor(),
    ].map<Interceptor>((it) => CaptureAwareInterceptor(it, () => hub.capturing)).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));

    await _startInternalProxy();

    final admin = AdminHandler(this);
    final frontDoor = ReverseProxyServer(configuration, listener: hub);
    frontDoor.initChannel((channel) {
      channel.dispatcher.handle(
        HttpRequestCodec(),
        HttpResponseCodec(),
        ReverseProxyChannelHandler(listener: hub, interceptors: interceptors, localHandler: admin.handle),
      );
    });
    await frontDoor.bind(ServerEnvironment.port, address: ServerEnvironment.bindAddress);
    _frontDoor = frontDoor;

    applyRetention();

    if (ServerEnvironment.testLoginEnabled) {
      logger.w('PROXYPIN_TEST_LOGIN is on: /api/test/login mints sessions without Google. '
          '${ServerEnvironment.boundToLoopback ? "Loopback only." : "REFUSED: the server is not bound to loopback."}');
    }

    logger.i('ProxyPin web listening on ${ServerEnvironment.bindAddress}:${ServerEnvironment.port} '
        '(UI ${ServerEnvironment.uiPrefix}/, data ${ServerEnvironment.dataDir})');
  }

  Future<void> _loadManagers() async {
    await EnvironmentManager.preload();
    final rules = await ReverseProxyManager.instance;
    logger.i('reverse proxy rules: ${rules.rules.length}');
    // warm the CA so the internal capture proxy can intercept HTTPS replays
    await CertificateManager.initCAConfig();
  }

  /// Loopback-only forward proxy used for "repeat"/request editor sends, so replays are captured and pass the
  /// interceptors exactly like the desktop app (which sends them through its own proxy port).
  Future<void> _startInternalProxy() async {
    final config = Configuration.fromJson({
      ...configuration.toJson(),
      'enableSsl': true,
      'enableSystemProxy': false,
      'enableSocks5': false,
    });
    _internalConfiguration = config;
    final server = Server(config, listener: hub);
    server.initChannel((channel) {
      channel.dispatcher.handle(
          HttpRequestCodec(), HttpResponseCodec(), HttpProxyChannelHandler(listener: hub, interceptors: interceptors));
    });
    final socket = await server.bind(0, address: InternetAddress.loopbackIPv4);
    internalProxyPort = socket.port;
    _internalProxy = server;
  }

  Future<void> _applyConfiguration(Map<String, dynamic> json) async {
    applyConfiguration(configuration, json);
    final internal = _internalConfiguration;
    if (internal != null) {
      internal
        ..externalProxy = configuration.externalProxy
        ..enabledHttp2 = configuration.enabledHttp2;
    }
  }

  // ------------------------------------------------------------------------------------------------- history

  /// The recorder of one user, writing into `<dataDir>/users/<id>/history`.
  ///
  /// Capture is shared (one proxy engine), but a saved session belongs to the person who pressed
  /// "save session", so every user gets their own task and their own history list.
  Future<HistoryTask> _historyTaskOf(AppUser user) async {
    final existing = _historyTasks[user.id];
    if (existing != null) return existing;

    final root = ServerEnvironment.userDataDir(user.storageKey);
    final storage = await HistoryStorage.forRoot(root);
    storage.addListener(OnchangeListEvent<HistoryItem>(_historyChanged));
    return _historyTasks[user.id] = HistoryTask(configuration, hub.container, storage: storage);
  }

  /// "Save session" from [user]'s browser: record the running capture into their history.
  Future<void> recordHistory(AppUser user) async {
    final task = await _historyTaskOf(user);
    hub.container.addListener(task);
    await task.startTask();
  }

  Timer? _historyTimer;

  /// Tells browsers to reload the history list when the server records into it.
  void _historyChanged() {
    _historyTimer?.cancel();
    _historyTimer = Timer(const Duration(milliseconds: 500), () => hub.broadcast({'type': 'configChanged', 'key': 'history'}));
  }

  void setCapturing(bool enabled) {
    hub.capturing = enabled;
    hub.broadcast({'type': 'capture', 'capturing': enabled});
  }

  Timer? _retentionTimer;

  /// Starts (or restarts) the admin's traffic retention sweep.
  ///
  /// The window is a rolling one: each sweep drops exchanges older than the configured period, so "weekly"
  /// keeps the last seven days rather than emptying everything every seventh day. Sweeping hourly is frequent
  /// enough for day-or-longer windows and costs nothing when there is nothing to drop.
  void applyRetention() {
    _retentionTimer?.cancel();
    _retentionTimer = null;

    final retention = authStore.settings.retention;
    if (retention == null) return;

    void sweep() {
      final removed = hub.clearOlderThan(retention);
      if (removed > 0) logger.i('traffic retention: dropped $removed exchanges older than ${retention.inHours}h');
    }

    sweep(); // apply the new window at once
    final period = retention < const Duration(hours: 2) ? const Duration(minutes: 5) : const Duration(hours: 1);
    _retentionTimer = Timer.periodic(period, (_) => sweep());
  }

  Future<void> stop() async {
    _retentionTimer?.cancel();
    await _frontDoor?.stop();
    await _internalProxy?.stop();
  }
}

