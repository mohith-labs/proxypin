/// package:code_forge in the desktop/mobile app; a TextField-based stand-in in the web UI (code_forge's Rust
/// core has no web build). Import this instead of package:code_forge.
library;

export 'package:code_forge/code_forge.dart' if (dart.library.js_interop) 'code_forge_web.dart';
