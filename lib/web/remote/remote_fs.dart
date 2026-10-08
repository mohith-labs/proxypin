import 'dart:typed_data';

import 'api_client.dart';

/// The server's data directory as seen by the web UI (backs File/Directory in lib/web/io/io_web.dart).
class RemoteFs {
  RemoteFs._();

  static Future<Uint8List?> read(String path) async {
    final response = await ApiClient.get('fs/read', query: {'path': path});
    if (response.statusCode == 404) return null;
    _ensureOk(response.statusCode, response.body, path);
    return response.bodyBytes;
  }

  static Future<void> write(String path, List<int> bytes, {bool append = false}) async {
    final response =
        await ApiClient.send('PUT', 'fs/write', query: {'path': path, if (append) 'append': '1'}, bytes: bytes);
    _ensureOk(response.statusCode, response.body, path);
  }

  static Future<RemoteStat> stat(String path) async =>
      RemoteStat.fromJson(await ApiClient.getJson('fs/stat', query: {'path': path}));

  static Future<List<RemoteStat>> list(String path, {bool recursive = false}) async {
    final json = await ApiClient.getJson('fs/list', query: {'path': path, if (recursive) 'recursive': '1'});
    return ((json['entries'] as List?) ?? const []).map((e) => RemoteStat.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  static Future<void> create(String path, {bool directory = false, bool recursive = false}) async {
    await ApiClient.postJson('fs/create',
        query: {'path': path, 'type': directory ? 'directory' : 'file', if (recursive) 'recursive': '1'});
  }

  static Future<void> delete(String path, {bool recursive = false}) async {
    await ApiClient.postJson('fs/delete', query: {'path': path, if (recursive) 'recursive': '1'});
  }

  static Future<void> rename(String path, String to) async {
    await ApiClient.postJson('fs/rename', query: {'path': path, 'to': to});
  }

  static Future<void> copy(String path, String to) async {
    await ApiClient.postJson('fs/copy', query: {'path': path, 'to': to});
  }

  static void _ensureOk(int status, String body, String path) {
    if (status >= 400) throw RemoteFsException('$path: HTTP $status $body');
  }
}

class RemoteStat {
  final String path;
  final String type;
  final int size;
  final DateTime modified;

  RemoteStat(this.path, this.type, this.size, this.modified);

  bool get exists => type != 'notFound';

  factory RemoteStat.fromJson(Map<String, dynamic> json) => RemoteStat(json['path'] ?? '', json['type'] ?? 'notFound',
      json['size'] ?? 0, DateTime.fromMillisecondsSinceEpoch(json['modified'] ?? 0));
}

class RemoteFsException implements Exception {
  final String message;

  RemoteFsException(this.message);

  @override
  String toString() => 'RemoteFsException: $message';
}
