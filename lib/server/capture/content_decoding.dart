import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/compress.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/zstd/zstd_server.dart' as zstd;

/// Removes Content-Encodings the browser cannot decode itself, so the web UI shows readable bodies right away:
/// brotli (package:brotli breaks once compiled to JavaScript) and zstd (no decoder in the browser).
/// gzip and deflate are left to the UI.
class ContentDecoding {
  ContentDecoding._();

  /// Bigger decoded bodies are not pushed with every event; the UI decodes them on demand instead.
  static const int maxDecodedLength = 8 * 1024 * 1024;

  /// The decoded body, or null when there is nothing to decode (or decoding failed).
  static List<int>? decodedBody(HttpMessage message) {
    final body = message.body;
    if (body == null || body.isEmpty) return null;
    try {
      final List<int>? decoded = switch (message.headers.contentEncoding?.trim()) {
        'br' => brDecode(body),
        'zstd' => zstd.decompressSync(body),
        _ => null,
      };
      // brDecode hands the input back when it cannot decode
      if (decoded == null || identical(decoded, body) || decoded.length > maxDecodedLength) return null;
      return decoded;
    } catch (e) {
      logger.d('cannot decode ${message.headers.contentEncoding} body: $e');
      return null;
    }
  }
}
