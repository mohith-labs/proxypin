/// Browser stand-in for the parts of `dart:io` the ProxyPin UI touches (exported by lib/utils/io.dart on web).
///
/// * [Platform] reports no native OS, so platform branches take their generic path instead of throwing.
/// * [File] / [Directory] are the ProxyPin server's data directory (lib/web/remote/remote_fs.dart): the
///   rule/script/history managers keep working unchanged and the server picks up every change.
///   `download://name` paths turn writes into browser downloads.
/// * gzip / zlib use package:archive.
/// * Sockets, processes and the like exist only so desktop-only code compiles; they throw if reached.
///
/// Names that ProxyPin itself declares (HttpHeaders, HttpStatus, ContentType, ProcessInfo, HttpRequest...) are
/// deliberately absent: unlike `dart:` declarations they would clash with the app's own classes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:web/web.dart' as web;

import '../remote/remote_fs.dart';
import 'memory_files.dart';
import 'web_download.dart';

// ---------------------------------------------------------------------------------------------------- platform

abstract final class Platform {
  static const String pathSeparator = '/';
  static const String operatingSystem = 'web';
  static const bool isAndroid = false;
  static const bool isIOS = false;
  static const bool isMacOS = false;
  static const bool isWindows = false;
  static const bool isLinux = false;
  static const bool isFuchsia = false;

  static String get operatingSystemVersion => web.window.navigator.userAgent;

  static Map<String, String> get environment => const {};

  static String get localeName => web.window.navigator.language;

  static String get localHostname => web.window.location.hostname;

  static int get numberOfProcessors => web.window.navigator.hardwareConcurrency;

  static String get resolvedExecutable => '';

  static String get executable => '';

  static Uri get script => Uri.base;

  static String get version => '';

  static List<String> get executableArguments => const [];

  static String get lineTerminator => '\n';
}

int get pid => 0;

Never exit(int code) => throw UnsupportedError('exit() is not available in the browser');

void sleep(Duration duration) {}

// -------------------------------------------------------------------------------------------------- exceptions

abstract class IOException implements Exception {}

class OSError implements Exception {
  final String message;
  final int errorCode;

  const OSError([this.message = '', this.errorCode = -1]);

  @override
  String toString() => 'OSError: $message, errno = $errorCode';
}

class FileSystemException implements IOException {
  final String message;
  final String? path;
  final OSError? osError;

  const FileSystemException([this.message = '', this.path = '', this.osError]);

  @override
  String toString() => 'FileSystemException: $message, path = \'$path\'';
}

class PathNotFoundException extends FileSystemException {
  const PathNotFoundException(String path, OSError osError, [String message = '']) : super(message, path, osError);
}

class SocketException implements IOException {
  final String message;
  final OSError? osError;

  const SocketException(this.message, {this.osError});

  @override
  String toString() => 'SocketException: $message';
}

class HttpException implements IOException {
  final String message;
  final Uri? uri;

  const HttpException(this.message, {this.uri});

  @override
  String toString() => 'HttpException: $message';
}

class TlsException implements IOException {
  final String type;
  final String message;
  final OSError? osError;

  const TlsException([this.message = '', this.osError]) : type = 'TlsException';

  @override
  String toString() => '$type: $message';
}

class HandshakeException extends TlsException {
  const HandshakeException([super.message, super.osError]);
}

class SignalException implements IOException {
  final String message;
  final dynamic osError;

  const SignalException(this.message, [this.osError]);

  @override
  String toString() => 'SignalException: $message';
}

class ProcessException implements IOException {
  final String executable;
  final List<String> arguments;
  final String message;
  final int errorCode;

  const ProcessException(this.executable, this.arguments, [this.message = '', this.errorCode = 0]);

  @override
  String toString() => 'ProcessException: $message';
}

// ------------------------------------------------------------------------------------------------- file system

class FileMode {
  final int _mode;

  const FileMode._(this._mode);

  static const read = FileMode._(0);
  static const write = FileMode._(1);
  static const append = FileMode._(2);
  static const writeOnly = FileMode._(3);
  static const writeOnlyAppend = FileMode._(4);

  bool get _isAppend => _mode == 2 || _mode == 4;

  @override
  String toString() => 'FileMode($_mode)';
}

class FileSystemEntityType {
  final String _name;

  const FileSystemEntityType._(this._name);

  static const file = FileSystemEntityType._('file');
  static const directory = FileSystemEntityType._('directory');
  static const link = FileSystemEntityType._('link');
  static const unixDomainSock = FileSystemEntityType._('unixDomainSock');
  static const pipe = FileSystemEntityType._('pipe');
  static const notFound = FileSystemEntityType._('notFound');

  static FileSystemEntityType _of(String name) => switch (name) {
        'file' => file,
        'directory' => directory,
        'link' => link,
        _ => notFound,
      };

  @override
  String toString() => _name;
}

class FileStat {
  final DateTime changed;
  final DateTime modified;
  final DateTime accessed;
  final FileSystemEntityType type;
  final int mode;
  final int size;

  FileStat._(this.type, this.size, this.modified)
      : changed = modified,
        accessed = modified,
        mode = 0;

  static Future<FileStat> stat(String path) async {
    final stat = await RemoteFs.stat(path);
    return FileStat._(FileSystemEntityType._of(stat.type), stat.size, stat.modified);
  }

  String modeString() => 'rw-r--r--';
}

String _parentOf(String path) {
  final trimmed = path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final index = trimmed.lastIndexOf('/');
  if (index <= 0) return '/';
  return trimmed.substring(0, index);
}

Never _sync(String operation) =>
    throw UnsupportedError('$operation: synchronous file access is not available in the browser');

abstract class FileSystemEntity {
  String get path;

  Uri get uri => Uri.file(path);

  Directory get parent => Directory(_parentOf(path));

  bool get isAbsolute => path.startsWith('/');

  Future<bool> exists();

  bool existsSync() => _sync('existsSync');

  Future<FileSystemEntity> delete({bool recursive = false});

  void deleteSync({bool recursive = false}) => _sync('deleteSync');

  Future<FileStat> stat() => FileStat.stat(path);

  Future<FileSystemEntity> rename(String newPath);

  static Future<FileSystemEntityType> type(String path, {bool followLinks = true}) async =>
      FileSystemEntityType._of((await RemoteFs.stat(path)).type);

  static Future<bool> isDirectory(String path) async => (await RemoteFs.stat(path)).type == 'directory';

  static Future<bool> isFile(String path) async => (await RemoteFs.stat(path)).type == 'file';

  static bool get isWatchSupported => false;
}

class File extends FileSystemEntity {
  @override
  final String path;

  File(this.path);

  factory File.fromUri(Uri uri) => File(uri.path);

  bool get _isDownload => WebDownload.isDownload(path);

  /// `localstorage://key` files live in this browser's localStorage (per-user UI preferences).
  static const String _localStorageScheme = 'localstorage://';

  bool get _isLocal => path.startsWith(_localStorageScheme);

  String get _localKey => 'proxypin:${path.substring(_localStorageScheme.length)}';

  File get absolute => this;

  @override
  Future<bool> exists() async {
    if (MemoryFiles.isMemory(path)) return MemoryFiles.read(path) != null;
    if (_isDownload) return false;
    if (_isLocal) return web.window.localStorage.getItem(_localKey) != null;
    return (await RemoteFs.stat(path)).type == 'file';
  }

  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    if (_isLocal) {
      if (web.window.localStorage.getItem(_localKey) == null) web.window.localStorage.setItem(_localKey, '');
      return this;
    }
    if (!_isDownload) await RemoteFs.create(path, recursive: recursive);
    return this;
  }

  void createSync({bool recursive = false, bool exclusive = false}) => _sync('createSync');

  @override
  Future<File> delete({bool recursive = false}) async {
    if (_isLocal) {
      web.window.localStorage.removeItem(_localKey);
      return this;
    }
    if (!_isDownload) await RemoteFs.delete(path);
    return this;
  }

  Future<Uint8List> readAsBytes() async {
    if (MemoryFiles.isMemory(path)) {
      final bytes = MemoryFiles.read(path);
      if (bytes == null) throw PathNotFoundException(path, const OSError('No such file or directory', 2));
      return bytes;
    }
    if (_isLocal) {
      final value = web.window.localStorage.getItem(_localKey);
      if (value == null) throw PathNotFoundException(path, const OSError('No such file or directory', 2));
      return utf8.encode(value);
    }
    final bytes = await RemoteFs.read(path);
    if (bytes == null) throw PathNotFoundException(path, const OSError('No such file or directory', 2));
    return bytes;
  }

  Uint8List readAsBytesSync() => _sync('readAsBytesSync');

  Future<String> readAsString({Encoding encoding = utf8}) async => encoding.decode(await readAsBytes());

  String readAsStringSync({Encoding encoding = utf8}) => _sync('readAsStringSync');

  Future<List<String>> readAsLines({Encoding encoding = utf8}) async =>
      const LineSplitter().convert(await readAsString(encoding: encoding));

  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) async {
    if (_isLocal) {
      final previous = mode._isAppend ? (web.window.localStorage.getItem(_localKey) ?? '') : '';
      web.window.localStorage.setItem(_localKey, previous + utf8.decode(bytes, allowMalformed: true));
      return this;
    }
    if (_isDownload) {
      mode._isAppend ? WebDownload.append(path, bytes) : WebDownload.save(WebDownload.nameOf(path), bytes);
      return this;
    }
    await RemoteFs.write(path, bytes, append: mode._isAppend);
    return this;
  }

  void writeAsBytesSync(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) =>
      _sync('writeAsBytesSync');

  Future<File> writeAsString(String contents,
          {FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false}) =>
      writeAsBytes(encoding.encode(contents), mode: mode, flush: flush);

  void writeAsStringSync(String contents, {FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false}) =>
      _sync('writeAsStringSync');

  Future<int> length() async =>
      MemoryFiles.isMemory(path) ? (MemoryFiles.read(path)?.length ?? 0) : (await RemoteFs.stat(path)).size;

  int lengthSync() => _sync('lengthSync');

  Future<DateTime> lastModified() async => (await RemoteFs.stat(path)).modified;

  @override
  Future<File> rename(String newPath) async {
    await RemoteFs.rename(path, newPath);
    return File(newPath);
  }

  Future<File> copy(String newPath) async {
    if (WebDownload.isDownload(newPath)) {
      WebDownload.save(WebDownload.nameOf(newPath), await readAsBytes());
      return File(newPath);
    }
    await RemoteFs.copy(path, newPath);
    return File(newPath);
  }

  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final initial = mode == FileMode.read || mode._isAppend ? (await RemoteFs.read(path)) : null;
    return RandomAccessFile._(this, mode, initial ?? Uint8List(0));
  }

  Stream<List<int>> openRead([int? start, int? end]) async* {
    final bytes = await readAsBytes();
    yield bytes.sublist(start ?? 0, end ?? bytes.length);
  }

  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) => IOSink._(this, mode, encoding);

  @override
  String toString() => "File: '$path'";
}

class Directory extends FileSystemEntity {
  @override
  final String path;

  Directory(this.path);

  Directory get absolute => this;

  static Directory get current => Directory('/');

  static Directory get systemTemp => Directory('/tmp');

  @override
  Future<bool> exists() async => (await RemoteFs.stat(path)).type == 'directory';

  Future<Directory> create({bool recursive = false}) async {
    await RemoteFs.create(path, directory: true, recursive: recursive);
    return this;
  }

  void createSync({bool recursive = false}) => _sync('createSync');

  @override
  Future<Directory> delete({bool recursive = false}) async {
    await RemoteFs.delete(path, recursive: recursive);
    return this;
  }

  @override
  Future<Directory> rename(String newPath) async {
    await RemoteFs.rename(path, newPath);
    return Directory(newPath);
  }

  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) async* {
    for (final entry in await RemoteFs.list(path, recursive: recursive)) {
      yield entry.type == 'directory' ? Directory(entry.path) : File(entry.path);
    }
  }

  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) => _sync('listSync');

  @override
  String toString() => "Directory: '$path'";
}

/// Buffered file handle: reads load the whole file, writes are sent on [flush]/[close].
class RandomAccessFile {
  final File _file;
  final FileMode _mode;
  final BytesBuilder _buffer = BytesBuilder();
  Uint8List _content;
  int _position;
  bool _dirty = false;

  RandomAccessFile._(this._file, this._mode, Uint8List content)
      : _content = content,
        _position = _mode._isAppend ? content.length : 0;

  String get path => _file.path;

  Future<RandomAccessFile> writeString(String string, {Encoding encoding = utf8}) => writeFrom(encoding.encode(string));

  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) async {
    _buffer.add(buffer.sublist(start, end ?? buffer.length));
    _dirty = true;
    return this;
  }

  Future<RandomAccessFile> writeByte(int value) => writeFrom([value]);

  Future<RandomAccessFile> flush() async {
    if (!_dirty) return this;
    final pending = _buffer.takeBytes();
    _dirty = false;
    if (_mode._isAppend) {
      await _file.writeAsBytes(pending, mode: FileMode.append);
      _content = Uint8List.fromList([..._content, ...pending]);
    } else {
      final merged = BytesBuilder(copy: false)
        ..add(_content.sublist(0, _position.clamp(0, _content.length)))
        ..add(pending);
      _content = merged.takeBytes();
      await _file.writeAsBytes(_content);
    }
    _position = _content.length;
    return this;
  }

  Future<void> close() async => flush();

  Future<int> length() async => _content.length + _buffer.length;

  Future<int> position() async => _position;

  Future<RandomAccessFile> setPosition(int position) async {
    await flush();
    _position = position;
    return this;
  }

  Future<RandomAccessFile> truncate(int length) async {
    await flush();
    _content = _content.sublist(0, length.clamp(0, _content.length));
    _position = _position.clamp(0, _content.length);
    await _file.writeAsBytes(_content);
    return this;
  }

  Future<Uint8List> read(int count) async {
    final end = (_position + count).clamp(0, _content.length);
    final bytes = _content.sublist(_position, end);
    _position = end;
    return bytes;
  }

  Future<RandomAccessFile> lock([dynamic mode, int start = 0, int end = -1]) async => this;

  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) async => this;
}

class IOSink implements StreamSink<List<int>>, StringSink {
  final File _file;
  final FileMode _mode;
  final BytesBuilder _buffer = BytesBuilder();
  final Completer<void> _done = Completer();
  Encoding encoding;

  IOSink._(this._file, this._mode, this.encoding);

  @override
  void add(List<int> data) => _buffer.add(data);

  @override
  void write(Object? object) => add(encoding.encode('$object'));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeAll(Iterable objects, [String separator = '']) => write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) => stream.forEach(add);

  Future flush() async {}

  @override
  Future close() async {
    await _file.writeAsBytes(_buffer.takeBytes(), mode: _mode);
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future get done => _done.future;
}

// ------------------------------------------------------------------------------------------------ compression

class GZipCodec extends Codec<List<int>, List<int>> {
  const GZipCodec({int level = 6, bool gzip = true});

  @override
  Converter<List<int>, List<int>> get decoder => const _GZipDecoder();

  @override
  Converter<List<int>, List<int>> get encoder => const _GZipEncoder();
}

const GZipCodec gzip = GZipCodec();

class _GZipDecoder extends Converter<List<int>, List<int>> {
  const _GZipDecoder();

  @override
  List<int> convert(List<int> input) => archive.GZipDecoder().decodeBytes(input);
}

class _GZipEncoder extends Converter<List<int>, List<int>> {
  const _GZipEncoder();

  @override
  List<int> convert(List<int> input) => archive.GZipEncoder().encodeBytes(input);
}

class ZLibCodec extends Codec<List<int>, List<int>> {
  final bool raw;

  const ZLibCodec({this.raw = false});

  @override
  Converter<List<int>, List<int>> get decoder => ZLibDecoder(raw: raw);

  @override
  Converter<List<int>, List<int>> get encoder => ZLibEncoder(raw: raw);
}

const ZLibCodec zlib = ZLibCodec();

class ZLibDecoder extends Converter<List<int>, List<int>> {
  final bool raw;

  const ZLibDecoder({this.raw = false, int windowBits = 15});

  @override
  List<int> convert(List<int> input) => archive.ZLibDecoder().decodeBytes(input, raw: raw);
}

class ZLibEncoder extends Converter<List<int>, List<int>> {
  final bool raw;

  const ZLibEncoder({this.raw = false, int level = 6});

  @override
  List<int> convert(List<int> input) {
    final encoded = archive.ZLibEncoder().encodeBytes(input);
    // raw deflate = zlib stream without the 2-byte header and 4-byte adler32 trailer
    return raw && encoded.length > 6 ? encoded.sublist(2, encoded.length - 4) : encoded;
  }
}

// ----------------------------------------------------------------------------- networking/process placeholders

Never _unsupported(String what) => throw UnsupportedError('$what is not available in the browser');

class InternetAddressType {
  final int _value;

  const InternetAddressType._(this._value);

  static const IPv4 = InternetAddressType._(0);
  static const IPv6 = InternetAddressType._(1);
  static const unix = InternetAddressType._(2);
  static const any = InternetAddressType._(-1);

  @override
  String toString() => 'InternetAddressType($_value)';
}

class InternetAddress {
  final String address;
  final InternetAddressType type;

  InternetAddress(this.address, {InternetAddressType? type}) : type = type ?? InternetAddressType.IPv4;

  String get host => address;

  bool get isLoopback => address == '127.0.0.1' || address == '::1';

  static final InternetAddress loopbackIPv4 = InternetAddress('127.0.0.1');
  static final InternetAddress anyIPv4 = InternetAddress('0.0.0.0');

  static InternetAddress? tryParse(String address) => InternetAddress(address);

  static Future<List<InternetAddress>> lookup(String host, {InternetAddressType type = InternetAddressType.any}) =>
      _unsupported('DNS lookup');

  @override
  String toString() => "InternetAddress('$address')";
}

class NetworkInterface {
  final String name;
  final int index;
  final List<InternetAddress> addresses;

  NetworkInterface._(this.name, this.index, this.addresses);

  /// The browser cannot enumerate interfaces.
  static Future<List<NetworkInterface>> list(
          {bool includeLoopback = false, bool includeLinkLocal = false, InternetAddressType type = InternetAddressType.any}) async =>
      const [];
}

abstract class Socket implements Stream<Uint8List> {
  static Future<Socket> connect(dynamic host, int port, {dynamic sourceAddress, int sourcePort = 0, Duration? timeout}) =>
      _unsupported('Socket');

  void destroy();

  Future close();
}

abstract class X509Certificate {
  String get subject;

  String get issuer;

  Uint8List get der;

  String get pem;
}

class ProcessStartMode {
  final int _mode;

  const ProcessStartMode._(this._mode);

  static const normal = ProcessStartMode._(0);
  static const inheritStdio = ProcessStartMode._(1);
  static const detached = ProcessStartMode._(2);
  static const detachedWithStdio = ProcessStartMode._(3);

  @override
  String toString() => 'ProcessStartMode($_mode)';
}

class ProcessResult {
  final int pid;
  final int exitCode;
  final dynamic stdout;
  final dynamic stderr;

  ProcessResult(this.pid, this.exitCode, this.stdout, this.stderr);
}

abstract class Process {
  static Future<ProcessResult> run(String executable, List<String> arguments,
          {String? workingDirectory,
          Map<String, String>? environment,
          bool includeParentEnvironment = true,
          bool runInShell = false,
          Encoding? stdoutEncoding,
          Encoding? stderrEncoding}) =>
      _unsupported('Process.run');

  static Future<Process> start(String executable, List<String> arguments,
          {String? workingDirectory,
          Map<String, String>? environment,
          bool includeParentEnvironment = true,
          bool runInShell = false,
          ProcessStartMode mode = ProcessStartMode.normal}) =>
      _unsupported('Process.start');

  static bool killPid(int pid, [dynamic signal]) => false;
}

/// Browser WebSocket with the subset of the dart:io API the WebSocket tool uses (custom headers cannot be set
/// from a browser and are ignored).
class WebSocket extends Stream<dynamic> implements StreamSink<dynamic> {
  static const int connecting = 0;
  static const int open = 1;
  static const int closing = 2;
  static const int closed = 3;

  final web.WebSocket _socket;
  final StreamController<dynamic> _messages = StreamController();
  final Completer<void> _done = Completer();
  int? closeCode;
  String? closeReason;

  WebSocket._(this._socket) {
    _socket.binaryType = 'arraybuffer';
    _socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (data == null) return;
      if (data.typeofEquals('string')) {
        _messages.add((data as JSString).toDart);
      } else if (data.instanceOfString('ArrayBuffer')) {
        _messages.add((data as JSArrayBuffer).toDart.asUint8List());
      }
    }).toJS;
    _socket.onclose = ((web.CloseEvent event) {
      closeCode = event.code;
      closeReason = event.reason;
      _messages.close();
      if (!_done.isCompleted) _done.complete();
    }).toJS;
    _socket.onerror = ((web.Event _) => _messages.addError(const SocketException('WebSocket error'))).toJS;
  }

  static Future<WebSocket> connect(String url, {Iterable<String>? protocols, Map<String, dynamic>? headers, dynamic compression}) {
    final socket = protocols == null
        ? web.WebSocket(url)
        : web.WebSocket(url, protocols.map((e) => e.toJS).toList().toJS);
    final completer = Completer<WebSocket>();
    final wrapper = WebSocket._(socket);
    socket.onopen = ((web.Event _) => completer.complete(wrapper)).toJS;
    wrapper._done.future.then((_) {
      if (!completer.isCompleted) completer.completeError(SocketException('WebSocket closed: ${wrapper.closeReason}'));
    });
    return completer.future;
  }

  int get readyState => _socket.readyState;

  String? get protocol => _socket.protocol;

  Duration? pingInterval;

  @override
  StreamSubscription<dynamic> listen(void Function(dynamic event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _messages.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  void add(dynamic data) {
    if (data is String) {
      _socket.send(data.toJS);
    } else if (data is List<int>) {
      _socket.send(Uint8List.fromList(data).toJS);
    }
  }

  void addUtf8Text(List<int> bytes) => _socket.send(utf8.decode(bytes).toJS);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) => stream.forEach(add);

  @override
  Future close([int? code, String? reason]) {
    if (code != null) {
      _socket.close(code, reason ?? '');
    } else {
      _socket.close();
    }
    return _done.future;
  }

  @override
  Future get done => _done.future;
}

class HttpClient {
  HttpClient({dynamic context}) {
    _unsupported('HttpClient');
  }
}
