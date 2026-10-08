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
  final AdminAuth auth = AdminAuth();
  final DateTime startedAt = DateTime.now();

  ReverseProxyServer? _frontDoor;
  Server? _internalProxy;
  Configuration? _internalConfiguration;
  HistoryTask? _historyTask;
  int? internalProxyPort;

  Future<void> start() async {
    configuration = await Configuration.instance;
    hub = CaptureHub(limit: ServerEnvironment.historyLimit);
    breakpoints = BreakpointBroker(hub);
    RequestBreakpointInterceptor.pauseTimeout = ServerEnvironment.breakpointTimeout;
    reloader = ConfigReloader(broadcast: hub.broadcast, onConfiguration: _applyConfiguration);

    await _loadManagers();
    ScriptManager.registerLogHandler(LogHandler(
        channelId: 'web', handle: (log) => hub.broadcast({'type': 'scriptLog', 'log': log.toJson()})));
    (await HistoryStorage.instance).addListener(OnchangeListEvent<HistoryItem>(_historyChanged));

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
    _startHistory();

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
    _startHistory();
  }

  // ------------------------------------------------------------------------------------------------- history

  /// Records the capture session into history automatically when "history cache time" is set (the desktop
  /// semantics), or from now on after the UI pressed "save session".
  void _startHistory() {
    final task = _historyTask ??= HistoryTask.ensureInstance(configuration, hub.container);
    if (configuration.historyCacheTime != 0) {
      hub.container.addListener(task);
    }
  }

  Future<void> recordHistory() async {
    final task = _historyTask ??= HistoryTask.ensureInstance(configuration, hub.container);
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

  Future<void> stop() async {
    await _frontDoor?.stop();
    await _internalProxy?.stop();
  }
}

