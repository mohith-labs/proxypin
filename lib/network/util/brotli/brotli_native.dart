import 'package:brotli/brotli.dart';

Future<List<int>?> decompress(List<int> bytes) async => brotli.decode(bytes);
