import 'dart:io';

import 'package:proxypin/server/auth/auth_store.dart';
import 'package:proxypin/server/server_environment.dart';

/// Thrown when a request asks for a path the signed-in user may not touch.
class ForbiddenPath implements Exception {
  final String message;

  ForbiddenPath(this.message);

  @override
  String toString() => message;
}

/// Maps the paths the web UI asks for onto the real files of one account.
///
/// The browser does not know about accounts: it asks for `<dataDir>/favorites.json` exactly like the
/// single-user build did. Personal files are redirected into `<dataDir>/users/<id>/`, so two people
/// signed into the same server never read or overwrite each other's data. Everything else (the proxy
/// engine's rules, scripts, uploaded files) stays shared, because one engine serves all of them.
class UserPaths {
  UserPaths._();

  /// Files that belong to one person.
  static const Set<String> perUserFiles = {'favorites.json', 'histories.json', 'ui_config.json'};

  /// Directories whose contents belong to one person (saved capture sessions).
  static const Set<String> perUserDirs = {'history'};

  /// Resolves [path] for [user], keeping it inside what that user may reach.
  ///
  /// Throws [ForbiddenPath] for traversal outside the data directory, and for another user's directory.
  static String confine(String? path, AppUser user, {String? dataDir}) {
    if (path == null || path.isEmpty) throw const FormatException('missing path');

    final root = normalize(Directory(dataDir ?? ServerEnvironment.dataDir).absolute.path);
    final resolved = normalize(File(path.startsWith('/') ? path : '$root/$path').absolute.path);

    if (resolved != root && !resolved.startsWith('$root$separator')) {
      throw ForbiddenPath('path outside the data directory: $path');
    }

    final userRoot = normalize('$root${separator}users$separator${user.storageKey}');

    // already addressed inside this user's own directory
    if (resolved == userRoot || resolved.startsWith('$userRoot$separator')) return resolved;

    // somebody else's directory: only an administrator may look there
    final usersRoot = '$root${separator}users';
    if (resolved == usersRoot || resolved.startsWith('$usersRoot$separator')) {
      if (user.isAdmin) return resolved;
      throw ForbiddenPath('path belongs to another user: $path');
    }

    final relative = resolved == root ? '' : resolved.substring(root.length + 1);
    final first = relative.contains(separator) ? relative.substring(0, relative.indexOf(separator)) : relative;
    if (perUserFiles.contains(relative) || perUserDirs.contains(first)) {
      return '$userRoot$separator$relative';
    }
    return resolved;
  }

  static String get separator => Platform.pathSeparator;

  static String normalize(String path) {
    final resolved = Uri.file(path).normalizePath().toFilePath();
    return resolved.length > 1 && resolved.endsWith(separator)
        ? resolved.substring(0, resolved.length - 1)
        : resolved;
  }
}
