// flutter_js (QuickJS / JavaScriptCore) runtime for the desktop and mobile app. Selected by the conditional import
// in script_engine.dart; never compiled into the web UI or the headless server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';
import 'package:proxypin/network/components/js/xhr.dart';

import '../../util/logger.dart';
import 'file.dart';
import 'md5.dart';
import 'script_engine.dart';

ScriptRuntime createScriptRuntime({required int poolSize, Function(dynamic args)? consoleLog}) =>
    FlutterScriptRuntime(JavaScriptRuntimePool(size: poolSize, consoleLog: consoleLog));

class FlutterScriptRuntime implements ScriptRuntime {
  final JavaScriptRuntimePool pool;

  FlutterScriptRuntime(this.pool);

  @override
  Future<dynamic> evaluate(String code) {
    return pool.run((flutterJs) async {
      var jsResult = await flutterJs.evaluateAsync(code);
      return await FlutterJsEngine.jsResultResolve(flutterJs, jsResult);
    });
  }

  @override
  Future<void> dispose() => pool.dispose();
}

class JavaScriptRuntimePool {
  final int size;
  final Function(dynamic args)? consoleLog;

  final List<_PooledJavaScriptRuntime> _runtimes = [];

  JavaScriptRuntimePool({required int size, this.consoleLog}) : size = size < 1 ? 1 : size;

  Future<T> run<T>(Future<T> Function(JavascriptRuntime flutterJs) action) async {
    final runtime = _selectRuntime();
    runtime.pending++;
    try {
      final flutterJs = await runtime.flutterJs.onError((error, stackTrace) {
        _runtimes.remove(runtime);
        throw error!;
      });
      return await FlutterJsEngine.synchronized(flutterJs, () => action(flutterJs));
    } on TimeoutException catch (e) {
      _runtimes.remove(runtime);
      logger.e('JavaScript runtime timed out and was removed from pool: $e');
      rethrow;
    } finally {
      runtime.pending--;
    }
  }

  Future<void> dispose() async {
    final runtimes = List<_PooledJavaScriptRuntime>.of(_runtimes);
    _runtimes.clear();
    for (final runtime in runtimes) {
      (await runtime.flutterJs).dispose();
    }
  }

  _PooledJavaScriptRuntime _selectRuntime() {
    for (final runtime in _runtimes) {
      if (runtime.pending == 0) {
        return runtime;
      }
    }

    if (_runtimes.length < size) {
      final runtime = _PooledJavaScriptRuntime(FlutterJsEngine.getJavaScript(consoleLog: consoleLog));
      _runtimes.add(runtime);
      return runtime;
    }

    return _runtimes.reduce((current, next) => current.pending <= next.pending ? current : next);
  }
}

class _PooledJavaScriptRuntime {
  final Future<JavascriptRuntime> flutterJs;
  int pending = 0;

  _PooledJavaScriptRuntime(this.flutterJs);
}

class FlutterJsEngine {
  static final _runtimeLocks = Expando<Future<void>>('javascriptRuntimeLocks');

  static Duration get runtimeTimeout => ScriptRuntime.timeout;

  static Future<T> synchronized<T>(JavascriptRuntime flutterJs, Future<T> Function() action) async {
    while (_runtimeLocks[flutterJs] != null) {
      await _runtimeLocks[flutterJs]!.timeout(runtimeTimeout);
    }

    final completer = Completer<void>();
    _runtimeLocks[flutterJs] = completer.future;
    var completed = false;
    try {
      return await action().timeout(runtimeTimeout);
    } finally {
      _runtimeLocks[flutterJs] = null;
      if (!completed) {
        completed = true;
        completer.complete();
      }
    }
  }

  static Future<JavascriptRuntime> getJavaScript({Function(dynamic args)? consoleLog}) async {
    final JavascriptRuntime flutterJs = getJavascriptRuntime(xhr: false);

    // register channel callback
    if (consoleLog != null) {
      final channelCallbacks = JavascriptRuntime.channelFunctionsRegistered[flutterJs.getEngineInstanceId()];
      channelCallbacks!["ConsoleLog"] = consoleLog;
    }
    Md5Bridge.registerMd5(flutterJs);
    FileBridge.registerFile(flutterJs);

    flutterJs.enableFetch2();
    return flutterJs;
  }

  /// js结果转换
  static Future<dynamic> jsResultResolve(JavascriptRuntime flutterJs, JsEvalResult jsResult) async {
    try {
      if (jsResult.isPromise || jsResult.rawResult is Future) {
        jsResult = await flutterJs.handlePromise(jsResult);
      }

      if (jsResult.isPromise || jsResult.rawResult is Future) {
        jsResult = await flutterJs.handlePromise(jsResult);
      }
    } catch (e) {
      throw SignalException(jsResult.stringResult);
    }

    var result = jsResult.rawResult;
    if (Platform.isMacOS || Platform.isIOS) {
      result = flutterJs.convertValue(jsResult);
    }
    if (result is String) {
      result = jsonDecode(result);
    }
    if (jsResult.isError) {
      logger.e('jsResultResolve error: ${jsResult.stringResult}');
      throw SignalException(jsResult.stringResult);
    }
    return result;
  }

}
