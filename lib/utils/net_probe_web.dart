import 'package:proxypin/web/remote/api_client.dart';

Future<bool> reachable(String host, int port, Duration timeout) async {
  try {
    final result =
        await ApiClient.postJson('net/probe', json: {'host': host, 'port': port, 'timeout': timeout.inMilliseconds});
    return result['reachable'] == true;
  } on ApiException catch (_) {
    return false;
  }
}
