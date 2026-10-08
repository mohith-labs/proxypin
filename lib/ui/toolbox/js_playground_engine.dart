/// Engine behind the JavaScript toolbox page: flutter_js in the desktop/mobile app, the ProxyPin server's Node.js
/// runtime in the web UI (same globals as interception scripts there).
library;

export 'js_playground_engine_flutter.dart' if (dart.library.js_interop) 'js_playground_engine_web.dart';
