import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';

Future<bool> isIpad() async {
  if (Platform.isIOS) {
    final deviceInfo = DeviceInfoPlugin();
    final iosInfo = await deviceInfo.iosInfo;
    return iosInfo.model.toLowerCase().contains('ipad');
  }
  return false;
}

Future<String?> saveFileAdaptive({required String fileName, List<String>? allowedExtensions, String? dialogTitle}) async {
  final uri = await FilePicker.saveFile(
    fileName: fileName,
    bytes: Uint8List(0),
    type: FileType.any,
    allowedExtensions: allowedExtensions,
    dialogTitle: dialogTitle,
  );
  if (uri == null) return null;
  return uri.scheme == 'file' ? uri.toFilePath() : null;
}
