import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/storage/histories.dart';

import 'api_client.dart';

/// History is recorded by the ProxyPin server (it sees all traffic, even with no browser open); "save session"
/// in the web UI asks the server to start recording the current session.
class WebHistoryTask extends HistoryTask {
  WebHistoryTask(super.configuration, super.sourceList);

  @override
  void onAdd(HttpRequest item) {}

  @override
  void onRemove(HttpRequest item) {}

  @override
  void onBatchRemove(List<HttpRequest> items) {}

  @override
  void clear(List<HttpRequest> items) {}

  @override
  Future<void> resetList() async {}

  @override
  Future<void> cleanHistory() async {}

  @override
  Future<void> writeTask() async {}

  @override
  void cancelTask() {}

  @override
  Future<void> startTask() async {
    await ApiClient.postJson('history/record');
  }
}
