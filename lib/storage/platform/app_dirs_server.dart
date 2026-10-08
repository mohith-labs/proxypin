// Headless server (plain Dart, no Flutter): every config file lives in one data directory and the bundled assets
// are read from disk. Both locations come from the environment (see lib/server/server_environment.dart).
import 'dart:io';
import 'dart:typed_data';

import 'package:proxypin/server/server_environment.dart';

Future<String> supportDirectory() async => ServerEnvironment.dataDir;

Future<String> userConfigDirectory() async => ServerEnvironment.dataDir;

Future<String> loadAssetString(String asset) => File(ServerEnvironment.assetPath(asset)).readAsString();

Future<Uint8List> loadAsset(String asset) => File(ServerEnvironment.assetPath(asset)).readAsBytes();

Future<Uint8List> readUserFile(String path) => File(path).readAsBytes();
