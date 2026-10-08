import 'package:file_picker/file_picker.dart';

Future<String?> readablePath(PlatformFile file) async => file.path;

Future<String?> enginePath(PlatformFile file) async => file.path;
