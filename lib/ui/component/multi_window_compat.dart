/// Desktop multi-window support: real OS windows (desktop_multi_window) in the app; in-page floating windows in
/// the web UI, where every "window" shares the main isolate.
library;

export 'multi_window_compat_native.dart' if (dart.library.js_interop) 'multi_window_compat_web.dart';
