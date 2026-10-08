// Web UI: configuration is stored on the ProxyPin server. Paths are the server's absolute paths; dart:io File on
// web is the remote file system in lib/web/io/ (see lib/utils/io.dart). Assets come from the web build.
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:proxypin/utils/io.dart';
import 'package:proxypin/web/web_environment.dart';

Future<String> supportDirectory() async => WebEnvironment.dataDir;

Future<String> userConfigDirectory() async => WebEnvironment.dataDir;

Future<String> loadAssetString(String asset) => rootBundle.loadString(asset);

Future<Uint8List> loadAsset(String asset) => rootBundle.load(asset).then((data) => data.buffer.asUint8List());

Future<Uint8List> readUserFile(String path) => File(path).readAsBytes();
