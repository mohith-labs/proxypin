import 'dart:typed_data';

import 'package:zstandard/zstandard.dart';

Future<List<int>?> decompress(List<int> bytes) => Zstandard().decompress(Uint8List.fromList(bytes));
