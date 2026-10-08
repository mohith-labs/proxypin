import 'package:proxypin/utils/io.dart';

import 'platform/app_dirs_server.dart'
    if (dart.library.js_interop) 'platform/app_dirs_web.dart'
    if (dart.library.ui) 'platform/app_dirs_flutter.dart' as dirs;

class Paths {
  static String? _homePath;
  static final Map<String, File> _cache = {};

  /// Application support directory path, with macOS multi-window IPC handling.
  ///
  /// Previously duplicated in ScriptManager, RequestMapManager,
  /// HostsManager, and RequestBreakpointManager.
  static Future<String> homePath() async {
    if (_homePath != null) return _homePath!;

    _homePath = await dirs.supportDirectory();
    return _homePath!;
  }

  //获取配置路径
  static Future<File> getPath(String fileName) async {
    if (_cache.containsKey(fileName)) {
      return _cache[fileName]!;
    }

    var file = File('${await homePath()}${Platform.pathSeparator}$fileName');

    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    _cache[fileName] = file;
    return file;
  }

  static Future<File> createFile(String dir, String filename) async {
    var file = File('${await homePath()}${Platform.pathSeparator}$dir${Platform.pathSeparator}$filename');
    return file.create(recursive: true);
  }
}
