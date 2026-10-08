/// `context.deviceId` exposed to scripts.
library;

export 'device_id_server.dart'
    if (dart.library.js_interop) 'device_id_web.dart'
    if (dart.library.ui) 'device_id_flutter.dart';
