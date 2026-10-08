/// OS proxy settings. Only the desktop/mobile app touches them; the headless server and the web UI get a no-op.
library;

export 'system_proxy_stub.dart'
    if (dart.library.js_interop) 'system_proxy_stub.dart'
    if (dart.library.ui) 'system_proxy_flutter.dart';
