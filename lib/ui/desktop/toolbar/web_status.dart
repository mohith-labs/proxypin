/// Toolbar items of the web UI (server connection, reverse-proxy rules); nothing in the desktop app.
library;

export 'web_status_stub.dart' if (dart.library.js_interop) 'web_status_web.dart';
