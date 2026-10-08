import 'dart:io';

/// Linux machine id (stable per container/volume), falling back to the host name.
Future<String?> scriptDeviceId() async {
  for (final path in ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
    try {
      final id = (await File(path).readAsString()).trim();
      if (id.isNotEmpty) return id;
    } catch (_) {}
  }
  return Platform.localHostname;
}
