import 'package:proxypin/web/remote/api_client.dart';

class JsPlaygroundEngine {
  final void Function(dynamic args) _consoleLog;

  JsPlaygroundEngine(this._consoleLog);

  /// Runs [code] on the ProxyPin server; returns the error text, or null on success.
  Future<String?> run(String code) async {
    try {
      final result = await ApiClient.postJson('script/run', json: {'code': code});
      for (final log in (result['logs'] as List?) ?? const []) {
        _consoleLog(List<dynamic>.from(log));
      }
      return result['error']?.toString();
    } catch (e) {
      return e.toString();
    }
  }

  void dispose() {}
}
