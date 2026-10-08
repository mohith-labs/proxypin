import 'dart:async';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/server/proxypin_web_server.dart';
import 'package:proxypin/server/server_environment.dart';

/// Headless ProxyPin: reverse proxy + web UI on one port. Configuration comes from the environment, see
/// lib/server/server_environment.dart (PORT, PROXYPIN_DATA_DIR, PROXYPIN_PASSWORD, ...).
void main(List<String> args) {
  // The engine closes sockets fire-and-forget (written for Flutter, whose zone reports such errors). In a plain
  // Dart process an unhandled async error is fatal, so one client resetting its connection would kill the server.
  runZonedGuarded(() => _run(args), (error, stack) {
    if (error is SocketException || error is StateError) {
      logger.d('connection error: $error');
    } else {
      logger.e('uncaught error', error: error, stackTrace: stack);
    }
  });
}

Future<void> _run(List<String> args) async {
  logger = Logger(
    filter: ProductionFilter(),
    level: (Platform.environment['PROXYPIN_LOG_LEVEL'] ?? 'info') == 'debug' ? Level.debug : Level.info,
    printer: SimplePrinter(printTime: true, colors: false),
    output: ConsoleOutput(),
  );

  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln('ProxyPin web server ${ServerEnvironment.uiPrefix}/ — configure with environment variables:\n'
        '  PORT (8080), PROXYPIN_BIND, PROXYPIN_DATA_DIR, PROXYPIN_WEB_DIR, PROXYPIN_USER, PROXYPIN_PASSWORD,\n'
        '  PROXYPIN_NODE, PROXYPIN_SCRIPT_WORKER, PROXYPIN_BREAKPOINT_TIMEOUT, PROXYPIN_HISTORY_LIMIT, PROXYPIN_LOG_LEVEL');
    return;
  }

  final server = ProxyPinWebServer();
  try {
    await server.start();
  } on SocketException catch (e) {
    stderr.writeln('cannot listen on ${ServerEnvironment.bindAddress}:${ServerEnvironment.port}: ${e.message}');
    exit(1);
  }

  if (!ServerEnvironment.authEnabled) {
    logger.w('UI authentication is off; set PROXYPIN_PASSWORD to require a login');
  }

  // docker stop sends SIGTERM; Ctrl+C sends SIGINT
  final signals = [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm];
  for (final signal in signals) {
    signal.watch().listen((_) async {
      logger.i('shutting down ($signal)');
      await server.stop().timeout(const Duration(seconds: 5), onTimeout: () {});
      exit(0);
    });
  }
}
