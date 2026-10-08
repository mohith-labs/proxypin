import 'dart:io';

import 'package:proxypin/network/http/http.dart' as http;

/// Serves the compiled Flutter web UI with ETags and gzip (main.dart.js and canvaskit.wasm are several MB).
class StaticFiles {
  final String root;
  final Map<String, _CachedGzip> _gzipCache = {};

  StaticFiles(this.root);

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'mjs': 'text/javascript; charset=utf-8',
    'json': 'application/json; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'wasm': 'application/wasm',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'svg': 'image/svg+xml',
    'ico': 'image/x-icon',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'txt': 'text/plain; charset=utf-8',
    'map': 'application/json; charset=utf-8',
    'frag': 'text/plain; charset=utf-8',
  };

  static const _compressible = {'html', 'js', 'mjs', 'json', 'css', 'wasm', 'svg', 'ttf', 'otf', 'txt', 'map', 'frag'};

  bool get available => File('$root/index.html').existsSync();

  /// [relativePath] is the URL path below the UI prefix, e.g. `main.dart.js`; empty means index.html.
  Future<http.HttpResponse> serve(http.HttpRequest request, String relativePath) async {
    var path = Uri.decodeComponent(relativePath);
    if (path.isEmpty || path.endsWith('/')) path = '${path}index.html';

    File? file = _resolve(path);
    // client-side routes fall back to the app shell
    if (file == null && !path.contains('.')) file = _resolve('index.html');
    if (file == null) return _notFound();

    final stat = await file.stat();
    final etag = '"${stat.modified.millisecondsSinceEpoch.toRadixString(36)}-${stat.size.toRadixString(36)}"';
    final extension = file.path.contains('.') ? file.path.substring(file.path.lastIndexOf('.') + 1).toLowerCase() : '';

    final response = http.HttpResponse(http.HttpStatus.ok)
      ..headers.set('Content-Type', _types[extension] ?? 'application/octet-stream')
      ..headers.set('ETag', etag)
      // index.html must be revalidated so a new build is picked up; everything else revalidates cheaply via ETag
      ..headers.set('Cache-Control', 'no-cache');

    if (request.headers.get('If-None-Match') == etag) {
      return http.HttpResponse(http.HttpStatus(304, 'Not Modified'))
        ..headers.set('ETag', etag)
        ..headers.set('Cache-Control', 'no-cache')
        ..headers.contentLength = 0
        ..body = const [];
    }

    List<int> body;
    final acceptsGzip = request.headers.get('Accept-Encoding')?.contains('gzip') ?? false;
    if (acceptsGzip && _compressible.contains(extension) && stat.size > 1024) {
      final cached = _gzipCache[file.path];
      if (cached != null && cached.etag == etag) {
        body = cached.bytes;
      } else {
        body = gzip.encode(await file.readAsBytes());
        _gzipCache[file.path] = _CachedGzip(etag, body);
      }
      response.headers.set('Content-Encoding', 'gzip');
      response.headers.set('Vary', 'Accept-Encoding');
    } else {
      body = await file.readAsBytes();
    }

    response.headers.contentLength = body.length;
    response.body = request.method == http.HttpMethod.head ? null : body;
    return response;
  }

  File? _resolve(String path) {
    final rootDir = Directory(root).absolute.path;
    final candidate = File('$rootDir/$path').absolute;
    final normalized = candidate.uri.normalizePath().toFilePath();
    if (!normalized.startsWith('$rootDir/')) return null; // no escaping the web root
    final file = File(normalized);
    return file.existsSync() ? file : null;
  }

  static http.HttpResponse _notFound() {
    const message = 'Not found';
    return http.HttpResponse(http.HttpStatus.notFound)
      ..headers.set('Content-Type', 'text/plain; charset=utf-8')
      ..headers.contentLength = message.length
      ..body = message.codeUnits;
  }
}

class _CachedGzip {
  final String etag;
  final List<int> bytes;

  _CachedGzip(this.etag, this.bytes);
}
