import 'package:flutter/services.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/ui/component/multi_window_compat_web.dart';

import 'remote/api_client.dart';
import 'web_environment.dart';

/// Main-window side of the desktop window protocol, for the web UI's in-page windows.
///
/// Settings windows already changed the shared managers and saved their files on the server (which reloads its
/// engine), so the desktop "refresh*" calls need no work here; breakpoint decisions go to the server.
Future<dynamic> webMainWindowHandler(MethodCall call, String fromWindowId) async {
  final arguments = call.arguments is Map ? Map<String, dynamic>.from(call.arguments as Map) : const <String, dynamic>{};
  switch (call.method) {
    case 'getProxyInfo':
      return {'host': '127.0.0.1', 'port': WebEnvironment.internalProxyPort ?? WebEnvironment.port};
    case 'registerConsoleLog':
      ScriptManager.registerLogHandler(LogHandler(
          channelId: 'web-console',
          handle: (log) => DesktopMultiWindow.invokeMethod('console', 'consoleLog', log.toJson())));
      return 'done';
    case 'resumeRequest':
      await ApiClient.postJson('breakpoint/resume',
          json: {'requestId': arguments['requestId'], 'phase': 'request', 'message': arguments['request']});
      return 'done';
    case 'resumeResponse':
      await ApiClient.postJson('breakpoint/resume',
          json: {'requestId': arguments['requestId'], 'phase': 'response', 'message': arguments['response']});
      return 'done';
  }
  return 'done';
}
