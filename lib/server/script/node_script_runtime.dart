import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:proxypin/network/components/js/script_engine.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/server/server_environment.dart';

/// Runs ProxyPin scripts in a Node.js worker process (server/js/script_worker.mjs).
///
/// flutter_js needs the Flutter embedder (and ships an x86-only Linux library), so the headless server delegates
/// to Node instead. One worker serves every runtime; each evaluation gets a fresh V8 context there.
class NodeScriptRuntime implements ScriptRuntime {
  final Function(dynamic args)? consoleLog;

  NodeScriptRuntime({this.consoleLog});

  @override
  Future<dynamic> evaluate(String code) =>
      NodeScriptWorker.shared.evaluate(code, timeout: ScriptRuntime.timeout, consoleLog: consoleLog);

  @override
  Future<void> dispose() async {}
}

class NodeScriptWorker {
  static final NodeScriptWorker shared = NodeScriptWorker();

  Process? _process;
  Future<Process>? _starting;
  int _nextId = 0;
  final Map<int, Completer<dynamic>> _pending = {};
  final Map<int, Function(dynamic args)?> _consoleLogs = {};

  Future<dynamic> evaluate(String code, {required Duration timeout, Function(dynamic args)? consoleLog}) async {
    final process = await _ensureStarted();
    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _consoleLogs[id] = consoleLog;
    process.stdin.writeln(jsonEncode({'id': id, 'type': 'eval', 'code': code, 'timeout': timeout.inMilliseconds}));

    // the worker enforces the timeout itself; this guards against a wedged worker
    return completer.future.timeout(timeout + const Duration(seconds: 5), onTimeout: () {
      throw SignalException('Script timed out after ${timeout.inSeconds}s');
    }).whenComplete(() {
      _pending.remove(id);
      _consoleLogs.remove(id);
    });
  }

  Future<Process> _ensureStarted() {
    final running = _process;
    if (running != null) return Future.value(running);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<Process> _start() async {
    final worker = ServerEnvironment.scriptWorker;
    if (!File(worker).existsSync()) {
      throw SignalException('Script worker not found: $worker (set PROXYPIN_SCRIPT_WORKER)');
    }

    final Process process;
    try {
      process = await Process.start(ServerEnvironment.nodeBinary, [worker],
          environment: {'PROXYPIN_DATA_DIR': ServerEnvironment.dataDir});
    } on ProcessException catch (e) {
      throw SignalException('Cannot start Node.js (${ServerEnvironment.nodeBinary}) for scripts: ${e.message}');
    }
    logger.i('script worker started (pid ${process.pid})');

    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      logger.w('script worker: $line');
    });
    unawaited(process.exitCode.then((code) {
      logger.w('script worker exited with $code');
      if (identical(_process, process)) _process = null;
      final pending = Map.of(_pending);
      _pending.clear();
      for (final completer in pending.values) {
        if (!completer.isCompleted) completer.completeError(SignalException('Script worker exited ($code)'));
      }
    }));

    _process = process;
    return process;
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(line);
    } catch (e) {
      logger.w('script worker: unexpected output $line');
      return;
    }

    final id = message['id'];
    switch (message['type']) {
      case 'log':
        final args = message['args'];
        final handler = id is int ? _consoleLogs[id] : null;
        if (handler != null && args is List) handler(List<dynamic>.of(args));
        return;
      case 'ready':
        return;
    }

    final completer = id is int ? _pending[id] : null;
    if (completer == null || completer.isCompleted) return;
    if (message['ok'] == true) {
      completer.complete(message['result']);
    } else {
      completer.completeError(SignalException(message['error']?.toString() ?? 'script error'));
    }
  }

  Future<void> dispose() async {
    _process?.kill();
    _process = null;
  }
}
