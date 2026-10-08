import 'package:logger/logger.dart';

/// Engine log. The headless server installs a production logger (the default filter drops everything in release
/// builds, which is right for the app but not for a server).
Logger logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 15,
      lineLength: 120,
      colors: true,
      printEmojis: false,
      excludeBox: {Level.info: true, Level.debug: true},
    ));
