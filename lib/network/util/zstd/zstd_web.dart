import 'package:proxypin/web/remote/remote_decoder.dart';

/// No zstd decoder in the browser; the ProxyPin server decodes it.
Future<List<int>?> decompress(List<int> bytes) => RemoteDecoder.zstd(bytes);
