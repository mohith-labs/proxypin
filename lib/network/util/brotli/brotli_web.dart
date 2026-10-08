import 'package:proxypin/web/remote/remote_decoder.dart';

/// package:brotli gives wrong results once compiled to JavaScript (it relies on 64-bit integer math), so the
/// ProxyPin server decodes brotli for the web UI.
Future<List<int>?> decompress(List<int> bytes) => RemoteDecoder.brotli(bytes);
