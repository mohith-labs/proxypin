import 'dart:typed_data';

import 'package:proxypin/utils/io.dart';

import '../../storage/platform/app_dirs_server.dart'
    if (dart.library.js_interop) '../../storage/platform/app_dirs_web.dart'
    if (dart.library.ui) '../../storage/platform/app_dirs_flutter.dart' as dirs;

class FileRead {
  /// Overrides the user home (tests): config then lives in `<userHome>/.proxypin`.
  static String? userHome;

  /// `~/.proxypin` on desktop (config.cnf, request_rewrite.json, request_crypto.json); the data directory on the
  /// headless server and web UI.
  static Future<File> homeDir() async {
    if (userHome != null) {
      return File("${userHome!}${Platform.pathSeparator}.proxypin");
    }
    return File(await dirs.userConfigDirectory());
  }

  /// Bundled asset (e.g. `assets/certs/ca.crt`).
  static Future<String> readAsString(String file) => dirs.loadAssetString(file);

  /// Bundled asset bytes.
  static Future<Uint8List> read(String file) => dirs.loadAsset(file);

  /// A file the user picked earlier (map-local / rewrite body files).
  static Future<Uint8List> readFile(String path) => dirs.readUserFile(path);
}
