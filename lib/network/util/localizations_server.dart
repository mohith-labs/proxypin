import 'dart:io';

/// Headless server: error pages follow PROXYPIN_LANG, falling back to the process locale.
bool get isZH {
  final lang = Platform.environment['PROXYPIN_LANG'] ?? Platform.environment['LANG'] ?? Platform.localeName;
  return lang.toLowerCase().startsWith('zh');
}
