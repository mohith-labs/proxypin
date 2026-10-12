/*
 * Copyright 2024 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'package:proxypin/utils/io.dart';

import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/hosts_manager.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/ui/component/liquid/liquid.dart';
import 'package:proxypin/ui/component/proxy_port_setting.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/mobile/menu/drawer.dart';
import 'package:proxypin/ui/mobile/menu/weak_network_tile.dart';
import 'package:proxypin/ui/mobile/setting/environment.dart';
import 'package:proxypin/ui/mobile/setting/hosts.dart';
import 'package:proxypin/ui/mobile/setting/mcp.dart';
import 'package:proxypin/ui/mobile/setting/preference.dart';
import 'package:proxypin/ui/mobile/mobile.dart';
import 'package:proxypin/ui/mobile/request/favorite.dart';
import 'package:proxypin/ui/mobile/request/history.dart';
import 'package:proxypin/ui/mobile/setting/request_block.dart';
import 'package:proxypin/ui/mobile/setting/request_crypto.dart';
import 'package:proxypin/ui/mobile/setting/request_rewrite.dart';
import 'package:proxypin/ui/mobile/setting/script.dart';
import 'package:proxypin/ui/mobile/setting/ssl.dart';
import 'package:proxypin/ui/mobile/widgets/about.dart';
import 'package:proxypin/ui/mobile/setting/request_breakpoint.dart';

import '../../../network/components/manager/request_breakpoint_manager.dart';
import '../../component/widgets.dart';
import '../setting/proxy.dart';
import '../setting/request_map.dart';

/// @author wanghongen
/// 2024/9/30
class ConfigPage extends StatefulWidget {
  final ProxyServer proxyServer;

  const ConfigPage({super.key, required this.proxyServer});

  @override
  State<StatefulWidget> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  late ProxyServer proxyServer = widget.proxyServer;
  late HistoryTask historyTask;

  @override
  void initState() {
    super.initState();
    historyTask = HistoryTask.ensureInstance(proxyServer.configuration, MobileApp.container);
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations localizations = AppLocalizations.of(context)!;

    Color color = Theme.of(context).colorScheme.primary.withValues(alpha: 0.85);

    // Glass grouped sections, iOS Settings style.
    int sectionIndex = 0;
    Widget section(List<Widget> tiles, {String? header}) => StaggeredEntrance(
          index: sectionIndex++,
          child: GlassSection(header: header, children: tiles),
        );

    Widget arrow = const SizedBox();

    return Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        appBar: LiquidGlassAppBar(title: Text(localizations.config)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            section(header: localizations.requests, [
              GlassTile(
                  leading: Icon(Icons.favorite_outline, color: color),
                  title: Text(localizations.favorites),
                  onTap: () => navigator(context, MobileFavorites(proxyServer: proxyServer))),
              GlassTile(
                leading: Icon(Icons.history, color: color),
                title: Text(localizations.history),
                onTap: () => navigator(context,
                    MobileHistory(proxyServer: proxyServer, container: MobileApp.container, historyTask: historyTask)),
              ),
            ]),
            const SizedBox(height: 12),
            section([
              GlassTile(
                  title: Text(localizations.hosts),
                  leading: Icon(Icons.domain, color: color),
                  onTap: () async {
                    var hostsManager = await HostsManager.instance;
                    if (context.mounted) {
                      navigator(context, HostsPage(hostsManager: hostsManager));
                    }
                  }),
              GlassTile(
                  title: Text(localizations.requestBlock),
                  leading: Icon(Icons.block_flipped, color: color),
                  onTap: () async {
                    var requestBlockManager = await RequestBlockManager.instance;
                    if (context.mounted) {
                      navigator(context, MobileRequestBlock(requestBlockManager: requestBlockManager));
                    }
                  }),
              GlassTile(
                  title: Text(localizations.requestRewrite),
                  leading: Icon(Icons.edit_outlined, color: color),
                  onTap: () async {
                    var requestRewrites = await RequestRewriteManager.instance;
                    if (context.mounted) {
                      navigator(context, MobileRequestRewrite(requestRewrites: requestRewrites));
                    }
                  }),
              GlassTile(
                  title: Text(localizations.requestMap),
                  leading: Icon(Icons.swap_horiz_outlined, color: color),
                  onTap: () => navigator(context, MobileRequestMapPage())),
              GlassTile(
                  title: Text(localizations.requestCrypto),
                  leading: Icon(Icons.lock_outline, color: color),
                  onTap: () => navigator(context, const MobileRequestCryptoPage())),
              GlassTile(
                  title: Text(localizations.script),
                  leading: Icon(Icons.javascript_outlined, color: color),
                  onTap: () => navigator(context, const MobileScript())),
              GlassTile(
                  title: Text(localizations.breakpoint),
                  leading: Icon(Icons.bug_report_outlined, color: color),
                  onTap: () async {
                    var manager = await RequestBreakpointManager.instance;
                    if (context.mounted) {
                      navigator(context, MobileRequestBreakpointPage(manager: manager));
                    }
                  }),
              WeakNetworkMenuTile(color: color, trailing: arrow),
              GlassTile(
                  title: Text(localizations.environmentVariables),
                  leading: Icon(Icons.public, color: color),
                  onTap: () => navigator(context, const MobileEnvironmentPage()))
            ]),
            const SizedBox(height: 16)
          ],
        ));
  }
}

void navigator(BuildContext context, Widget widget) async {
  if (context.mounted) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (BuildContext context) => widget),
    );
  }
}

class SettingPage extends StatelessWidget {
  final ProxyServer proxyServer;
  final AppConfiguration appConfiguration;

  const SettingPage({super.key, required this.proxyServer, required this.appConfiguration});

  @override
  Widget build(BuildContext context) {
    final configuration = proxyServer.configuration;

    var textEditingController = TextEditingController(text: configuration.proxyPassDomains);

    AppLocalizations localizations = AppLocalizations.of(context)!;
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    int sectionIndex = 0;
    Widget section(List<Widget> tiles, {String? header}) => StaggeredEntrance(
          index: sectionIndex++,
          child: GlassSection(header: header, children: tiles),
        );

    return Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        appBar: LiquidGlassAppBar(title: Text(localizations.setting)),
        body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
          section([
            GlassTile(
                title: Text(localizations.httpsProxy),
                onTap: () => navigator(context, MobileSslWidget(proxyServer: proxyServer))),
            GlassTile(
                title: Text(localizations.filter),
                onTap: () => navigator(context, FilterMenu(proxyServer: proxyServer))),
          ]),
          const SizedBox(height: 12),
          // Port and switches
          GlassSection(children: [
                PortWidget(
                    proxyServer: proxyServer,
                    title: '${localizations.proxy}${isCN ? '' : ' '}${localizations.port}',
                    textStyle: const TextStyle(fontSize: 16)),
                if (Platform.isAndroid)
                  GlassTile(
                      title: Text(localizations.systemProxy),
                      trailing: SwitchWidget(
                          value: configuration.enableSystemProxy,
                          scale: 0.8,
                          onChanged: (value) {
                            configuration.enableSystemProxy = value;
                            proxyServer.configuration.flushConfig();
                          })),
                GlassTile(
                    title: const Text("SOCKS5"),
                    trailing: SwitchWidget(
                        value: configuration.enableSocks5,
                        scale: 0.8,
                        onChanged: (value) {
                          configuration.enableSocks5 = value;
                          proxyServer.configuration.flushConfig();
                        })),
                GlassTile(
                    title: Text(localizations.enabledHTTP2),
                    trailing: SwitchWidget(
                        value: configuration.enabledHttp2,
                        scale: 0.8,
                        onChanged: (value) {
                          configuration.enabledHttp2 = value;
                          proxyServer.configuration.flushConfig();
                        })),
                GlassTile(
                    title: Text(localizations.externalProxy),
                        onTap: () {
                      showDialog(
                          context: context,
                          builder: (_) => ExternalProxyDialog(configuration: proxyServer.configuration));
                    }),

                Padding(
                    padding: const EdgeInsets.only(left: 15),
                    child: Row(children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(localizations.proxyIgnoreDomain, style: const TextStyle(fontSize: 14)),
                          const SizedBox(height: 3),
                          Text(isCN ? "多个使用;分割" : "Use ';' to separate multiple entries",
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                        ],
                      ),
                      Padding(
                          padding: const EdgeInsets.only(left: 35),
                          child: TextButton(
                            child: Text(localizations.reset),
                            onPressed: () {
                              textEditingController.text = SystemProxy.proxyPassDomains;
                            },
                          ))
                    ])),
                const SizedBox(height: 5),
                Padding(
                    padding: const EdgeInsets.only(left: 15, right: 5),
                    child: TextField(
                        textInputAction: TextInputAction.done,
                        style: const TextStyle(fontSize: 13),
                        controller: textEditingController,
                        onSubmitted: (_) {
                          configuration.proxyPassDomains = textEditingController.text;
                          proxyServer.configuration.flushConfig();
                        },
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.all(10),
                          border: OutlineInputBorder(),
                        ),
                        maxLines: 5,
                        minLines: 1)),
                const SizedBox(height: 10),
              ]),
          const SizedBox(height: 12),
          section([
            GlassTile(
                title: Text(localizations.mcpService),
                onTap: () => navigator(context, MobileMcpSetting(proxyServer: proxyServer))),
            GlassTile(
                title: Text(localizations.setting),
                onTap: () =>
                    navigator(context, Preference(proxyServer: proxyServer, appConfiguration: appConfiguration))),
            GlassTile(
                title: Text(localizations.about),
                onTap: () => navigator(context, const About())),
          ]),
          const SizedBox(height: 8),
        ]));
  }
}
