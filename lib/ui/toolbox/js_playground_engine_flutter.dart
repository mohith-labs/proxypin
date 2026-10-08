import 'package:flutter_js/flutter_js.dart';
import 'package:proxypin/network/components/js/file.dart';
import 'package:proxypin/network/components/js/md5.dart';
import 'package:proxypin/network/components/js/xhr.dart';

class JsPlaygroundEngine {
  //重置环境
  static bool resetEnvironment = true;

  static JavascriptRuntime? _flutterJs;

  JsPlaygroundEngine(void Function(dynamic args) consoleLog) {
    if (resetEnvironment || _flutterJs == null) {
      _flutterJs = getJavascriptRuntime(xhr: false);
    }
    final flutterJs = _flutterJs!;
    // register channel callback
    final channelCallbacks = JavascriptRuntime.channelFunctionsRegistered[flutterJs.getEngineInstanceId()];
    channelCallbacks!["ConsoleLog"] = consoleLog;
    Md5Bridge.registerMd5(flutterJs);
    FileBridge.registerFile(flutterJs);
    flutterJs.enableFetch2(enabledProxy: true);
  }

  /// Runs [code]; returns the error text, or null on success.
  Future<String?> run(String code) async {
    var jsResult = await _flutterJs!.evaluateAsync(code);
    if (jsResult.isPromise || jsResult.rawResult is Future) {
      jsResult = await _flutterJs!.handlePromise(jsResult);
    }
    return jsResult.isError ? jsResult.toString() : null;
  }

  void dispose() {
    if (resetEnvironment) {
      _flutterJs?.dispose();
      _flutterJs = null;
    }
  }
}
