import 'package:proxypin/utils/io.dart';

import 'platform_plugins_stub.dart'
    if (dart.library.js_interop) 'platform_plugins_web.dart'
    if (dart.library.ui) 'platform_plugins_flutter.dart' as plugins;

/// Whether this code runs in the browser (the web UI). Same definition as Flutter's `kIsWeb`, but usable from the
/// Flutter-free headless server too.
const bool kIsWebPlatform = bool.fromEnvironment('dart.library.js_interop');

class Platforms {
  /// 判断是否是web端
  static bool get isWeb => kIsWebPlatform;

  /// 判断是否是桌面端
  static bool isDesktop() {
    return !kIsWebPlatform && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  }

  /// 判断是否是移动端
  static bool isMobile() {
    return !kIsWebPlatform && (Platform.isAndroid || Platform.isIOS);
  }

  /// 判断是否是ipad
  static Future<bool> isIpad() => plugins.isIpad();

  /// 桌面端保存文件：只弹对话框选路径并返回，不自动写入。
  /// 调用方拿到路径后自行转换 bytes 并写入，避免用户取消时浪费性能。
  /// 移动端请直接使用 FilePicker.saveFile。
  /// Web: returns a `download://<fileName>` path; writing to it downloads the file in the browser.
  static Future<String?> saveFileAdaptive({
    required String fileName,
    List<String>? allowedExtensions,
    String? dialogTitle,
  }) =>
      plugins.saveFileAdaptive(fileName: fileName, allowedExtensions: allowedExtensions, dialogTitle: dialogTitle);
}
