import 'dart:async';
import 'dart:io';

import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/http.dart' as http;
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/network/util/app_version.dart';
import 'package:proxypin/network/util/compress.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/remote/wire.dart';
import 'package:proxypin/server/admin/admin_http.dart';
import 'package:proxypin/server/auth/auth_store.dart';
import 'package:proxypin/server/auth/user_paths.dart';
import 'package:proxypin/server/script/node_script_runtime.dart';
import 'package:proxypin/server/server_environment.dart';

import '../proxypin_web_server.dart';

/// REST endpoints below `/__proxypin/api/`. The web UI persists everything through the file endpoints (its
/// managers use the same JSON files as the desktop app), so the rest is mostly runtime actions.
class AdminApi {
  final ProxyPinWebServer server;

  AdminApi(this.server);

  /// [path] is relative to `/__proxypin/api/` (e.g. `fs/read`). [user] is the signed-in account: it decides
  /// which data directory the file endpoints see, and whether the admin endpoints are allowed.
  Future<http.HttpResponse> handle(
      http.HttpRequest request, String path, Map<String, String> query, AppUser user) async {
    final method = request.method;
    try {
      if (path.startsWith('admin/')) return await _admin(request, path.substring(6), user);

      switch (path) {
        case 'info':
          return AdminHttp.json(info(user));
        case 'capture':
          final enabled = AdminHttp.jsonBody(request)['enabled'] != false;
          server.setCapturing(enabled);
          return AdminHttp.json({'capturing': enabled});
        case 'traffic/clear':
          server.hub.clear();
          return AdminHttp.json({'ok': true});
        case 'request/send':
          return await _send(request);
        case 'breakpoint/resume':
          final body = AdminHttp.jsonBody(request);
          final resumed = server.breakpoints.resume(body['requestId'], body['phase'] ?? 'request', body['message']);
          return AdminHttp.json({'resumed': resumed});
        case 'script/run':
          return await _runScript(request);
        case 'decode/zstd':
          final decoded = await zstdDecode(request.body ?? const []);
          return AdminHttp.bytes(200, decoded ?? const []);
        case 'decode/br': // package:brotli does not work in the browser build
          return AdminHttp.bytes(200, brDecode(request.body ?? const []));
        case 'history/record':
          await server.recordHistory(user);
          return AdminHttp.json({'ok': true});
        case 'net/probe':
          return AdminHttp.json(await _probe(AdminHttp.jsonBody(request)));
      }

      if (path.startsWith('fs/')) return await _fileSystem(method, path.substring(3), query, request, user);
      return AdminHttp.error(404, 'unknown endpoint $path');
    } on FormatException catch (e) {
      return AdminHttp.error(400, e.message);
    } on ForbiddenPath catch (e) {
      return AdminHttp.error(403, e.message);
    } catch (e, t) {
      logger.e('admin api $path failed', error: e, stackTrace: t);
      return AdminHttp.error(500, e.toString());
    }
  }

  Map<String, dynamic> info([AppUser? user]) => {
        'version': appVersion,
        'dataDir': ServerEnvironment.dataDir,
        'port': ServerEnvironment.port,
        'uiPrefix': ServerEnvironment.uiPrefix,
        'capturing': server.hub.capturing,
        'pathSeparator': Platform.pathSeparator,
        'os': Platform.operatingSystem,
        'internalProxyPort': server.internalProxyPort,
        'authRequired': true,
        'user': user?.toPublicJson(),
        'isAdmin': user?.isAdmin == true,
        'startedAt': server.startedAt.millisecondsSinceEpoch,
      };

  /// Whether `host:port` accepts TCP connections from the server (e.g. an external proxy the UI is configuring).
  static Future<Map<String, dynamic>> _probe(Map<String, dynamic> body) async {
    final host = body['host']?.toString() ?? '';
    final port = body['port'];
    if (host.isEmpty || port is! int || port <= 0 || port > 65535) throw const FormatException('host and port required');
    final timeout = Duration(milliseconds: (body['timeout'] as int? ?? 1000).clamp(100, 10000));
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return {'reachable': true};
    } on SocketException catch (e) {
      return {'reachable': false, 'error': e.message};
    }
  }

  Future<http.HttpResponse> _send(http.HttpRequest request) async {
    final body = AdminHttp.jsonBody(request);
    final outgoing = Wire.requestFrom(Map<String, dynamic>.from(body['request']));
    final timeout = Duration(milliseconds: (body['timeout'] as num?)?.toInt() ?? 30000);
    final proxyPort = server.internalProxyPort;
    try {
      // through the internal capture proxy, like the desktop app sends through its own proxy
      final response = await HttpClients.proxyRequest(outgoing,
          proxyInfo: proxyPort == null ? null : ProxyInfo.of('127.0.0.1', proxyPort), timeout: timeout);
      return AdminHttp.json({'response': Wire.response(response)});
    } on TimeoutException {
      return AdminHttp.error(504, 'request timed out after ${timeout.inSeconds}s');
    } catch (e) {
      return AdminHttp.error(502, e.toString());
    }
  }

  Future<http.HttpResponse> _runScript(http.HttpRequest request) async {
    final body = AdminHttp.jsonBody(request);
    final code = body['code']?.toString() ?? '';
    final timeout = Duration(milliseconds: (body['timeout'] as num?)?.toInt() ?? 30000);
    final logs = <List<dynamic>>[];
    try {
      final result = await NodeScriptWorker.shared
          .evaluate(code, timeout: timeout, consoleLog: (args) => logs.add(List<dynamic>.from(args)));
      return AdminHttp.json({'result': result, 'logs': logs});
    } on SignalException catch (e) {
      return AdminHttp.json({'error': e.message, 'logs': logs});
    }
  }

  // --------------------------------------------------------------------------------------------- admin

  /// `/__proxypin/api/admin/*`: user administration, restricted to the accounts in PROXYPIN_ADMIN_EMAIL.
  Future<http.HttpResponse> _admin(http.HttpRequest request, String action, AppUser user) async {
    if (!user.isAdmin) return AdminHttp.error(403, 'administrator access required');
    final store = await AuthStore.instance;

    switch (action) {
      case 'users':
        return AdminHttp.json({
          'users': store.users.map((e) => e.toPublicJson()).toList(),
          'settings': store.settings.toJson(),
          'adminEmails': ServerEnvironment.adminEmails,
        });

      case 'settings':
        final body = AdminHttp.jsonBody(request);
        final settings = store.settings;
        if (body.containsKey('allowSignup')) settings.allowSignup = body['allowSignup'] == true;
        if (body.containsKey('domainMode')) settings.domainMode = domainModeFrom(body['domainMode']?.toString());
        if (body.containsKey('domains')) {
          settings.domains = ((body['domains'] as List?) ?? const [])
              .map((e) => AuthSettings.normalizeDomain(e.toString()))
              .where((e) => e.isNotEmpty)
              .toSet()
              .toList();
        }
        await store.updateSettings(settings);
        return AdminHttp.json({'settings': settings.toJson()});

      case 'user/status':
        final body = AdminHttp.jsonBody(request);
        final target = store.byId(body['id']?.toString());
        if (target == null) return AdminHttp.error(404, 'unknown user');
        if (target.isAdmin) return AdminHttp.error(403, 'the administrator account cannot be changed');

        final status = userStatusFrom(body['status']?.toString());
        await store.setStatus(target, status);
        // a blocked (or un-approved) user must lose access right away, not when their cookie expires
        if (status != UserStatus.approved) server.auth.revokeSessionsOf(target.id);
        return AdminHttp.json({'user': target.toPublicJson()});

      case 'user/delete':
        final body = AdminHttp.jsonBody(request);
        final target = store.byId(body['id']?.toString());
        if (target == null) return AdminHttp.error(404, 'unknown user');
        if (target.isAdmin) return AdminHttp.error(403, 'the administrator account cannot be removed');

        server.auth.revokeSessionsOf(target.id);
        await store.remove(target.id);
        if (body['deleteData'] == true) {
          final dir = Directory(ServerEnvironment.userDataDir(target.storageKey));
          if (await dir.exists()) await dir.delete(recursive: true);
        }
        return AdminHttp.json({'ok': true});
    }
    return AdminHttp.error(404, 'unknown admin endpoint $action');
  }

  // ---------------------------------------------------------------------------------------------- file system

  Future<http.HttpResponse> _fileSystem(http.HttpMethod method, String action, Map<String, String> query,
      http.HttpRequest request, AppUser user) async {
    final path = _confine(query['path'], user);
    final source = request.headers.get('X-ProxyPin-Client');
    void changed(String path) => server.reloader.changed(path, source: source);
    switch (action) {
      case 'read':
        final file = File(path);
        if (!await file.exists()) return AdminHttp.error(404, 'not found');
        return AdminHttp.bytes(200, await file.readAsBytes());
      case 'stat':
        return AdminHttp.json(await _stat(path));
      case 'list':
        final dir = Directory(path);
        if (!await dir.exists()) return AdminHttp.json({'entries': []});
        final recursive = query['recursive'] == '1';
        final entries = <Map<String, dynamic>>[];
        await for (final entity in dir.list(recursive: recursive, followLinks: false)) {
          entries.add(await _stat(entity.path));
        }
        return AdminHttp.json({'entries': entries});
      case 'write':
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(request.body ?? const [],
            mode: query['append'] == '1' ? FileMode.append : FileMode.write, flush: true);
        changed(path);
        return AdminHttp.json({'ok': true, 'size': await file.length()});
      case 'create':
        if (query['type'] == 'directory') {
          await Directory(path).create(recursive: query['recursive'] == '1');
        } else {
          final file = File(path);
          if (query['recursive'] == '1') await file.parent.create(recursive: true);
          if (!await file.exists()) await file.create();
          changed(path);
        }
        return AdminHttp.json(await _stat(path));
      case 'delete':
        final type = await FileSystemEntity.type(path);
        if (type == FileSystemEntityType.directory) {
          await Directory(path).delete(recursive: query['recursive'] == '1');
        } else if (type != FileSystemEntityType.notFound) {
          await File(path).delete();
        }
        changed(path);
        return AdminHttp.json({'ok': true});
      case 'rename':
      case 'copy':
        final target = _confine(query['to'], user);
        await Directory(File(target).parent.path).create(recursive: true);
        if (action == 'rename') {
          await FileSystemEntity.type(path) == FileSystemEntityType.directory
              ? await Directory(path).rename(target)
              : await File(path).rename(target);
          changed(path);
        } else {
          await File(path).copy(target);
        }
        changed(target);
        return AdminHttp.json(await _stat(target));
    }
    return AdminHttp.error(404, 'unknown file operation $action');
  }

  static Future<Map<String, dynamic>> _stat(String path) async {
    final stat = await FileStat.stat(path);
    final type = switch (stat.type) {
      FileSystemEntityType.file => 'file',
      FileSystemEntityType.directory => 'directory',
      FileSystemEntityType.link => 'link',
      _ => 'notFound',
    };
    return {
      'path': path,
      'type': type,
      'exists': type != 'notFound',
      'size': type == 'notFound' ? 0 : stat.size,
      'modified': type == 'notFound' ? 0 : stat.modified.millisecondsSinceEpoch,
    };
  }

  /// Resolves a path from the UI into the signed-in user's own files (see [UserPaths]).
  static String _confine(String? path, AppUser user) => UserPaths.confine(path, user);
}
