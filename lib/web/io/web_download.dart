import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Browser downloads behind the desktop "save file" flow: `Platforms.saveFileAdaptive` returns a
/// `download://<name>` path and writing to it (see io_web.dart File) saves the bytes through the browser.
class WebDownload {
  WebDownload._();

  static const String scheme = 'download://';

  static String pathFor(String fileName) => '$scheme$fileName';

  static bool isDownload(String path) => path.startsWith(scheme);

  static String nameOf(String path) => path.substring(scheme.length);

  static final Map<String, BytesBuilder> _pending = {};
  static final Map<String, Timer> _timers = {};

  /// Appends are collected and saved once the writer goes quiet.
  static void append(String path, List<int> bytes) {
    (_pending[path] ??= BytesBuilder()).add(bytes);
    _timers.remove(path)?.cancel();
    _timers[path] = Timer(const Duration(milliseconds: 400), () {
      _timers.remove(path);
      final data = _pending.remove(path);
      if (data != null) save(nameOf(path), data.takeBytes());
    });
  }

  static void save(String fileName, List<int> bytes, {String? mimeType}) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final blob = web.Blob([data.toJS].toJS, web.BlobPropertyBag(type: mimeType ?? _mimeType(fileName)));
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = fileName
      ..style.display = 'none';
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
  }

  static String _mimeType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.json') || lower.endsWith('.har')) return 'application/json';
    if (lower.endsWith('.txt') || lower.endsWith('.js') || lower.endsWith('.pem') || lower.endsWith('.crt')) {
      return 'text/plain';
    }
    return 'application/octet-stream';
  }
}
