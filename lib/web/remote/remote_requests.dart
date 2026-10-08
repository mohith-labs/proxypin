import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/remote/wire.dart';

import 'api_client.dart';

/// "Repeat" / request editor sends from the web UI: the server sends them through its capture pipeline (so
/// they show up in the list and pass rewrite/script/breakpoint rules), exactly like the desktop app does.
class RemoteRequests {
  RemoteRequests._();

  static Future<HttpResponse> send(HttpRequest request, Duration timeout) async {
    request.hostAndPort ??= HostAndPort.of(request.requestUrl);
    final result = await ApiClient.postJson('request/send',
        json: {'request': Wire.request(request), 'timeout': timeout.inMilliseconds});
    return Wire.responseFrom(Map<String, dynamic>.from(result['response']), request: request);
  }
}
