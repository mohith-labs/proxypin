import 'package:brotli/brotli.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/utils/io.dart';

import 'brotli/brotli_native.dart' if (dart.library.js_interop) 'brotli/brotli_web.dart' as br;
import 'zstd/zstd_server.dart'
    if (dart.library.js_interop) 'zstd/zstd_web.dart'
    if (dart.library.ui) 'zstd/zstd_flutter.dart' as zstd;

///GZIP 解压缩
List<int> gzipDecode(List<int> byteBuffer) {
  GZipCodec gzipCodec = GZipCodec();
  try {
    return gzipCodec.decode(byteBuffer);
  } catch (e) {
    logger.e("gzipDecode error: $e");
    return byteBuffer;
  }
}

///GZIP 压缩
List<int> gzipEncode(List<int> input) {
  return GZipCodec().encode(input);
}

///br 解压缩
List<int> brDecode(List<int> byteBuffer) {
  try {
    return brotli.decode(byteBuffer);
  } catch (e) {
    logger.e("brDecode error: $e");
    return byteBuffer;
  }
}

///br 解压缩, usable in every build (the web UI has the server decode it, see brotli_web.dart)
Future<List<int>> brDecodeAsync(List<int> byteBuffer) async {
  try {
    return await br.decompress(byteBuffer) ?? byteBuffer;
  } catch (e) {
    logger.e("brDecode error: $e");
    return byteBuffer;
  }
}

///zstd 解压缩
Future<List<int>?> zstdDecode(List<int> byteBuffer) async {
  try {
    return await zstd.decompress(byteBuffer);
  } catch (e) {
    logger.e("zstdDecode error: $e");
    return byteBuffer;
  }
}


///deflate: zlib-wrapped as the HTTP spec defines it (RFC 9110), though some servers send raw deflate
List<int> zlibDecode(List<int> byteBuffer) {
  final zlibHeader = byteBuffer.length > 2 &&
      (byteBuffer[0] & 0x0f) == 8 &&
      (byteBuffer[0] >> 4) <= 7 &&
      ((byteBuffer[0] << 8) | byteBuffer[1]) % 31 == 0;
  if (zlibHeader) {
    try {
      return ZLibDecoder().convert(byteBuffer);
    } catch (_) {
      // a raw stream that happens to start like a zlib header
    }
  }
  try {
    final rawDeflateDecoder = ZLibDecoder(raw: true);
    return rawDeflateDecoder.convert(byteBuffer);
  } catch (e) {
    logger.e("zlibDecode error: $e");
    return byteBuffer;
  }
}