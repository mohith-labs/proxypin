// Headless server: no devices or save dialogs.
Future<bool> isIpad() async => false;

Future<String?> saveFileAdaptive({required String fileName, List<String>? allowedExtensions, String? dialogTitle}) async =>
    null;
