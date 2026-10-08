import 'package:proxypin/network/components/js/script_engine.dart';
import 'package:proxypin/utils/io.dart';

import 'api_client.dart';

/// Runs JavaScript on the ProxyPin server (Node.js), the same environment interception scripts use there.
class RemoteScriptRuntime implements ScriptRuntime {
  final Function(dynamic args)? consoleLog;

  RemoteScriptRuntime({this.consoleLog});

  @override
  Future<dynamic> evaluate(String code) async {
    final result = await ApiClient.postJson('script/run', json: {'code': code, 'timeout': ScriptRuntime.timeout.inMilliseconds});
    for (final log in (result['logs'] as List?) ?? const []) {
      consoleLog?.call(List<dynamic>.from(log));
    }
    if (result['error'] != null) throw SignalException(result['error'].toString());
    return result['result'];
  }

  @override
  Future<void> dispose() async {}
}
