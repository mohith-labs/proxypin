import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proxypin/main.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/manager/environment_manager.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_manager.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/ui/component/multi_window_compat_web.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/desktop.dart';
import 'package:web/web.dart' as web;

import 'remote/api_client.dart';
import 'remote/remote_proxy_server.dart';
import 'remote/remote_requests.dart';
import 'remote/web_history_task.dart';
import 'web_environment.dart';
import 'web_ipc.dart';

/// Entry point of the web UI (served by the ProxyPin server below /__proxypin/).
Future<void> runWebApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  final Map<String, dynamic> session;
  try {
    session = await ApiClient.getJson('session');
  } catch (e) {
    runApp(
        _MessageApp(title: 'ProxyPin server unreachable', message: '$e', onRetry: () => web.window.location.reload()));
    return;
  }

  if (session['authenticated'] != true) {
    runApp(_LoginApp(
      signInUrl: session['signInUrl']?.toString() ?? '/__proxypin/auth/google/start',
      googleConfigured: session['googleConfigured'] == true,
      adminConfigured: session['adminConfigured'] == true,
    ));
    return;
  }

  try {
    await _start();
  } catch (e, t) {
    logger.e('web start failed', error: e, stackTrace: t);
    runApp(_MessageApp(title: 'ProxyPin failed to start', message: '$e', onRetry: () => web.window.location.reload()));
  }
}

Future<void> _start() async {
  WebEnvironment.apply(await ApiClient.getJson('info'));

  // engine features that need sockets or files run on the server
  DesktopMultiWindow.webMainHandler = webMainWindowHandler;
  HttpClients.remoteSender = RemoteRequests.send;
  HistoryTask.factory = (configuration, list) => WebHistoryTask(configuration, list);
  ApiClient.onUnauthorized.listen((_) => web.window.location.reload());

  final appConfiguration = await AppConfiguration.instance;
  final configuration = await Configuration.instance;
  await EnvironmentManager.preload();
  await ReverseProxyManager.instance;

  final server = RemoteProxyServer(configuration);

  runApp(FluentApp(DesktopHomePage(configuration, appConfiguration, proxyServer: server), appConfiguration));
}

class _LoginApp extends StatelessWidget {
  final String signInUrl;
  final bool googleConfigured;
  final bool adminConfigured;

  const _LoginApp({required this.signInUrl, required this.googleConfigured, required this.adminConfigured});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ProxyPin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.blue, brightness: Brightness.dark, useMaterial3: true),
      home: Builder(builder: _page), // Theme.of needs a context below MaterialApp
    );
  }

  Widget _page(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('ProxyPin', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 6),
                Text('Sign in to the web console',
                    textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                const SizedBox(height: 28),
                if (googleConfigured)
                  _GoogleButton(onPressed: () => web.window.location.href = signInUrl)
                else
                  _notice(
                      theme,
                      'Google sign-in is not configured on this server. Set PROXYPIN_GOOGLE_CLIENT_ID and '
                      'PROXYPIN_GOOGLE_CLIENT_SECRET, then restart it.'),
                if (googleConfigured && !adminConfigured) ...[
                  const SizedBox(height: 18),
                  _notice(theme, 'No administrator is configured: set PROXYPIN_ADMIN_EMAIL to manage users.'),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _notice(ThemeData theme, String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
      );
}

/// "Sign in with Google" button, following Google's branding guidance closely enough to be recognisable.
class _GoogleButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _GoogleButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        backgroundColor: dark ? const Color(0xFF131314) : Colors.white,
        foregroundColor: dark ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F),
        side: BorderSide(color: dark ? const Color(0xFF8E918F) : const Color(0xFFDADCE0)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
        const _GoogleLogo(size: 18),
        const SizedBox(width: 12),
        const Text('Sign in with Google', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

/// The Google "G", drawn so the UI needs no bundled image asset.
class _GoogleLogo extends StatelessWidget {
  final double size;

  const _GoogleLogo({required this.size});

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: size, child: CustomPaint(painter: _GoogleLogoPainter()));
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final center = Offset(s / 2, s / 2);
    final stroke = s * 0.22;
    final radius = (s - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // four brand-coloured arcs, starting at the right-hand gap of the G
    const segments = <List<double>>[
      [-0.30, 1.10], // blue   (right/top)
      [0.80, 1.35], // green  (bottom right)
      [2.15, 1.25], // yellow (bottom left)
      [3.40, 1.40], // red    (top left)
    ];
    const colors = [Color(0xFF4285F4), Color(0xFF34A853), Color(0xFFFBBC05), Color(0xFFEA4335)];
    for (var i = 0; i < segments.length; i++) {
      canvas.drawArc(rect, segments[i][0], segments[i][1], false, paint..color = colors[i]);
    }

    // the horizontal bar of the G
    canvas.drawRect(
      Rect.fromLTRB(center.dx, center.dy - stroke / 2, s - stroke * 0.1, center.dy + stroke / 2),
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MessageApp extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback onRetry;

  const _MessageApp({required this.title, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ProxyPin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: SelectableText(message)),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ]),
        ),
      ),
    );
  }
}
