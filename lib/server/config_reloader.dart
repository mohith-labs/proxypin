import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/manager/environment_manager.dart';
import 'package:proxypin/network/components/manager/hosts_manager.dart';
import 'package:proxypin/network/components/manager/network_condition_manager.dart';
import 'package:proxypin/network/components/manager/report_server_manager.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/components/manager/request_crypto_manager.dart';
import 'package:proxypin/network/components/manager/request_map_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_manager.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/server/server_environment.dart';
import 'package:proxypin/storage/histories.dart';

/// The web UI saves rules/scripts by writing the same files the desktop app uses; this reloads the live engine
/// managers when one of them changes and tells the other browsers to refresh.
class ConfigReloader {
  final void Function(Map<String, dynamic> event) broadcast;
  final Future<void> Function(Map<String, dynamic> config) onConfiguration;

  final Map<String, Timer> _pending = {};
  final Map<String, Set<String>> _sources = {};

  ConfigReloader({required this.broadcast, required this.onConfiguration});

  /// [path] is an absolute path inside the data directory; [source] identifies the browser tab that wrote it
  /// (tabs skip reloading their own writes).
  void changed(String path, {String? source}) {
    final relative = _relative(path);
    if (relative == null) return;
    final key = _reloadKey(relative);
    if (key == null) return;
    (_sources[key] ??= {}).add(source ?? 'server');
    _pending.remove(key)?.cancel();
    _pending[key] = Timer(const Duration(milliseconds: 250), () async {
      _pending.remove(key);
      final sources = _sources.remove(key) ?? const {};
      try {
        await _reload(key);
      } catch (e, t) {
        logger.e('reload $key failed', error: e, stackTrace: t);
      }
      broadcast({'type': 'configChanged', 'key': key, 'path': relative, 'sources': sources.toList()});
    });
  }

  static String? _relative(String path) {
    final root = ServerEnvironment.dataDir;
    if (path == root) return '';
    if (!path.startsWith('$root/')) return null;
    return path.substring(root.length + 1);
  }

  /// Which manager owns [relative] (rule lists plus their per-rule item files).
  static String? _reloadKey(String relative) {
    final first = relative.split('/').first;
    return switch (first) {
      'config.cnf' => 'config',
      'request_rewrite.json' || 'rewrite' => 'rewrite',
      'script.json' || 'scripts' => 'script',
      'request_map.json' || 'request_map' => 'map',
      'request_block.json' => 'block',
      'request_breakpoint.json' => 'breakpoint',
      'request_crypto.json' => 'crypto',
      'hosts.json' => 'hosts',
      'environments.json' => 'environment',
      'network_condition.json' => 'networkCondition',
      'report_servers.json' => 'reportServers',
      ReverseProxyManager.fileName => 'reverseProxy',
      'histories.json' || 'history' => 'history',
      'favorites.json' => 'favorites',
      _ => null,
    };
  }

  Future<void> _reload(String key) async {
    switch (key) {
      case 'config':
        final file = File('${ServerEnvironment.dataDir}/config.cnf');
        if (await file.exists()) {
          final content = await file.readAsString();
          if (content.trim().isNotEmpty) await onConfiguration(jsonDecode(content));
        }
      case 'rewrite':
        await (await RequestRewriteManager.instance).reloadRequestRewrite();
      case 'script':
        await (await ScriptManager.instance).reloadScript();
      case 'map':
        await (await RequestMapManager.instance).reloadConfig();
      case 'block':
        await (await RequestBlockManager.instance).reload();
      case 'breakpoint':
        await (await RequestBreakpointManager.instance).load();
      case 'crypto':
        await (await RequestCryptoManager.instance).reloadConfig();
      case 'hosts':
        await (await HostsManager.instance).load();
      case 'environment':
        await (await EnvironmentManager.instance).reload();
      case 'networkCondition':
        await (await NetworkConditionManager.instance).reload();
      case 'reportServers':
        await (await ReportServerManager.instance).loadConfig();
      case 'reverseProxy':
        await (await ReverseProxyManager.instance).reload();
      case 'history':
        await (await HistoryStorage.instance).reload();
    }
  }
}

/// Re-applies config.cnf to the running [Configuration] (the parsed copy also reloads the host filters).
void applyConfiguration(Configuration target, Map<String, dynamic> json) {
  final fresh = Configuration.fromJson(json);
  target
    ..externalProxy = fresh.externalProxy
    ..historyCacheTime = fresh.historyCacheTime
    ..proxyPassDomains = fresh.proxyPassDomains
    ..enabledHttp2 = fresh.enabledHttp2
    ..appWhitelist = fresh.appWhitelist
    ..appWhitelistEnabled = fresh.appWhitelistEnabled
    ..appBlacklist = fresh.appBlacklist;
}
