// Web UI: scripts are executed by the ProxyPin server (POST /__proxypin/api/script/run).
import 'package:proxypin/web/remote/remote_script_runtime.dart';

import 'script_engine.dart';

ScriptRuntime createScriptRuntime({required int poolSize, Function(dynamic args)? consoleLog}) =>
    RemoteScriptRuntime(consoleLog: consoleLog);
