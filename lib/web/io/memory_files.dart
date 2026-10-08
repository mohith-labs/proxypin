import 'dart:typed_data';

/// Files the user picked in the browser, readable through `File('memory://<id>/<name>')` (see io_web.dart).
class MemoryFiles {
  MemoryFiles._();

  static const String scheme = 'memory://';
  static final Map<String, Uint8List> _files = {};
  static int _next = 0;

  static String register(String name, Uint8List bytes) {
    final path = '$scheme${_next++}/$name';
    _files[path] = bytes;
    // keep the most recent picks only
    if (_files.length > 16) _files.remove(_files.keys.first);
    return path;
  }

  static bool isMemory(String path) => path.startsWith(scheme);

  static Uint8List? read(String path) => _files[path];
}
