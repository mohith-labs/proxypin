/// Flutter's [ChangeNotifier] in the app (UI widgets listen to the managers), a pure-Dart equivalent on the
/// headless server where `package:flutter` is unavailable.
library;

export 'change_notifier_dart.dart' if (dart.library.ui) 'package:flutter/foundation.dart' show ChangeNotifier;
