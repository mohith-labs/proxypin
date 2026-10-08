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

  if (session['authRequired'] == true && session['authenticated'] != true) {
    runApp(_LoginApp(user: session['user']?.toString()));
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

class _LoginApp extends StatefulWidget {
  final String? user;

  const _LoginApp({this.user});

  @override
  State<_LoginApp> createState() => _LoginAppState();
}

class _LoginAppState extends State<_LoginApp> {
  late final TextEditingController _user = TextEditingController(text: widget.user ?? 'admin');
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiClient.postJson('login', json: {'username': _user.text, 'password': _password.text});
      web.window.location.reload();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
          constraints: const BoxConstraints(maxWidth: 360),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: AutofillGroup(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('ProxyPin', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                  const SizedBox(height: 4),
                  Text('Sign in to the web console', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _user,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofocus: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                    onSubmitted: (_) => _login(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _busy ? null : _login, child: const Text('Sign in')),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
