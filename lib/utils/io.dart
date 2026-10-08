/// `dart:io` for the Flutter app and the headless server. In the browser (web UI) `dart:io` compiles but throws on
/// use, so the web build gets a stand-in: a safe [Platform], a [File]/[Directory] backed by the ProxyPin server's
/// data directory, gzip/zlib codecs, and stubs for sockets and processes that the web UI never reaches.
///
/// Import this instead of `dart:io` in code that is part of the web UI.
library;

export 'dart:io' if (dart.library.js_interop) 'package:proxypin/web/io/io_web.dart';
