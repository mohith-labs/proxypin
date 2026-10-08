// Flutter desktop/mobile: platform directories via path_provider and bundled assets via rootBundle.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:proxypin/utils/platform.dart';

/// Application support directory (rules, scripts, histories, favorites, certificates).
Future<String> supportDirectory() => getApplicationSupportDirectory().then((it) => it.path);

/// `~/.proxypin` on desktop, `<support>/.proxypin` on mobile (config.cnf, rewrite and crypto rules).
Future<String> userConfigDirectory() async {
  var separator = Platform.pathSeparator;
  if (Platforms.isDesktop()) {
    var userHome = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return "$userHome$separator.proxypin";
  }
  return "${await supportDirectory()}$separator.proxypin";
}

Future<String> loadAssetString(String asset) => rootBundle.loadString(asset);

Future<Uint8List> loadAsset(String asset) => rootBundle.load(asset).then((data) => data.buffer.asUint8List());

String? _iosUuid;

/// Reads a file chosen by the user earlier; on iOS the app container UUID changes between installs.
Future<Uint8List> readUserFile(String path) async {
  if (Platform.isIOS) {
    _iosUuid ??= _containerUuid(await supportDirectory());
    var uuidPattern = RegExp(r'/Application/[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/');
    path = path.replaceAll(uuidPattern, '/Application/$_iosUuid/');
  }
  return File(path).readAsBytes();
}

String? _containerUuid(String applicationPath) {
  var uuidPattern = RegExp(r'/Application/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/');
  return uuidPattern.firstMatch(applicationPath)?.group(1);
}
