// Headless server: scripts run in the Node.js worker.
import 'package:proxypin/server/script/node_script_runtime.dart';

import 'script_engine.dart';

ScriptRuntime createScriptRuntime({required int poolSize, Function(dynamic args)? consoleLog}) =>
    NodeScriptRuntime(consoleLog: consoleLog);
