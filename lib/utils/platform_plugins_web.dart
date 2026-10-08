import 'package:proxypin/web/io/web_download.dart';

Future<bool> isIpad() async => false;

/// The browser has no save dialog that returns a path; hand back a virtual path whose writes become a download.
Future<String?> saveFileAdaptive({required String fileName, List<String>? allowedExtensions, String? dialogTitle}) async =>
    WebDownload.pathFor(fileName);
