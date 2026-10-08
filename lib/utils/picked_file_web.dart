import 'package:file_picker/file_picker.dart';
import 'package:proxypin/web/io/memory_files.dart';
import 'package:proxypin/web/remote/remote_fs.dart';
import 'package:proxypin/web/web_environment.dart';

Future<String?> readablePath(PlatformFile file) async => MemoryFiles.register(file.name, await file.xFile.readAsBytes());

Future<String?> enginePath(PlatformFile file) async {
  final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final path = '${WebEnvironment.dataDir}/files/${DateTime.now().millisecondsSinceEpoch}-$safeName';
  await RemoteFs.write(path, await file.xFile.readAsBytes());
  return path;
}
