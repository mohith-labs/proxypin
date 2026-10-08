import 'api_client.dart';

/// Content decoding the browser cannot do itself.
class RemoteDecoder {
  RemoteDecoder._();

  static Future<List<int>?> zstd(List<int> bytes) async {
    final response = await ApiClient.send('POST', 'decode/zstd', bytes: bytes);
    return response.statusCode == 200 ? response.bodyBytes : null;
  }

  static Future<List<int>?> brotli(List<int> bytes) async {
    final response = await ApiClient.send('POST', 'decode/br', bytes: bytes);
    return response.statusCode == 200 ? response.bodyBytes : null;
  }
}
