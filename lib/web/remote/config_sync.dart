import 'dart:convert';

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
import 'package:proxypin/network/util/file_read.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/storage/favorites.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/utils/io.dart';

import 'api_client.dart';

/// Keeps this tab's managers in step with the server: another tab (or the server itself, e.g. a script
/// updating an environment variable, or history recording) changed one of the shared config files.
class ConfigSync {
  ConfigSync._();

  static Future<void> onChanged(Map<String, dynamic> event) async {
    final sources = (event['sources'] as List?)?.cast<String>() ?? const [];
    if (sources.isNotEmpty && sources.every((it) => it == ApiClient.clientId)) return; // our own write
    final key = event['key'];
    try {
      switch (key) {
        case 'config':
          final configuration = await Configuration.instance;
          final file = File('${(await FileRead.homeDir()).path}/config.cnf');
          if (await file.exists()) {
            final fresh = Configuration.fromJson(jsonDecode(await file.readAsString()));
            configuration
              ..externalProxy = fresh.externalProxy
              ..historyCacheTime = fresh.historyCacheTime;
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
        case 'favorites':
          await FavoriteStorage.reload();
      }
    } catch (e, t) {
      logger.w('sync $key failed', error: e, stackTrace: t);
    }
  }
}
