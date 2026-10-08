import 'package:file_picker/file_picker.dart';

import 'picked_file_native.dart' if (dart.library.js_interop) 'picked_file_web.dart' as impl;

/// Paths for files chosen with file_picker that work in every build. In the browser a picked file has no
/// filesystem path, so the web build hands out stand-in paths instead.
class PickedFiles {
  PickedFiles._();

  /// A path `File(...)` can read right away in this UI (imports, toolbox "open file").
  static Future<String?> readablePath(PlatformFile? file) async => file == null ? null : impl.readablePath(file);

  /// A path the proxy engine can read later, e.g. a map-local or rewrite body file. The web UI uploads the file
  /// to the ProxyPin server's data directory and returns that server path.
  static Future<String?> enginePath(PlatformFile? file) async => file == null ? null : impl.enginePath(file);
}
