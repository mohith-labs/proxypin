import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/desktop/setting/reverse_proxy.dart';
import 'package:proxypin/web/remote/api_client.dart';
import 'package:proxypin/web/remote/remote_proxy_server.dart';
import 'package:proxypin/web/web_environment.dart';
import 'package:web/web.dart' as web;

/// Server connection state and quick access to the reverse-proxy rules.
class WebServerStatus extends StatelessWidget {
  const WebServerStatus({super.key});

  @override
  Widget build(BuildContext context) {
    final server = RemoteProxyServer.instance;
    final localizations = AppLocalizations.of(context)!;
    if (server == null) return const SizedBox.shrink();

    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
          tooltip: localizations.reverseProxy,
          icon: const Icon(Icons.alt_route, size: 21),
          onPressed: () => openReverseProxyWindow(context)),
      const SizedBox(width: 8),
      ValueListenableBuilder<RemoteConnection>(
        valueListenable: server.connection,
        builder: (context, connection, _) => ValueListenableBuilder<bool>(
          valueListenable: server.capturing,
          builder: (context, capturing, _) {
            if (connection == RemoteConnection.disconnected) {
              return _chip(context, Icons.cloud_off, localizations.webConsoleDisconnected, Colors.red);
            }
            if (connection == RemoteConnection.connecting) {
              return const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2));
            }
            if (!capturing) return _chip(context, Icons.pause_circle_outline, localizations.capturePaused, Colors.orange);
            return const SizedBox.shrink();
          },
        ),
      ),
      if (WebEnvironment.authRequired) ...[
        const SizedBox(width: 4),
        IconButton(
            tooltip: '${localizations.webSignOut} (${WebEnvironment.user ?? ''})',
            icon: const Icon(Icons.logout, size: 19),
            onPressed: () async {
              try {
                await ApiClient.postJson('logout');
              } finally {
                web.window.location.reload();
              }
            }),
      ],
    ]);
  }

  static Widget _chip(BuildContext context, IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 12, color: color)),
      ]),
    );
  }
}
