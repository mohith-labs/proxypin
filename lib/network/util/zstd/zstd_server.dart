import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// zstd Content-Encoding on the headless server: streaming decompression through the system libzstd
/// (Debian `libzstd1`), so multi-frame bodies and frames without a content size both work.
Future<List<int>?> decompress(List<int> bytes) async => _Zstd.instance?.decompress(bytes);

/// Same as [decompress]; the FFI calls are synchronous anyway (null when libzstd is missing).
List<int>? decompressSync(List<int> bytes) => _Zstd.instance?.decompress(bytes);

final class _InBuffer extends Struct {
  external Pointer<Void> src;
  @Size()
  external int size;
  @Size()
  external int pos;
}

final class _OutBuffer extends Struct {
  external Pointer<Void> dst;
  @Size()
  external int size;
  @Size()
  external int pos;
}

class _Zstd {
  static final _Zstd? instance = _load();

  final Pointer<Void> Function() _createDStream;
  final int Function(Pointer<Void>) _freeDStream;
  final int Function(Pointer<Void>) _initDStream;
  final int Function(Pointer<Void>, Pointer<_OutBuffer>, Pointer<_InBuffer>) _decompressStream;
  final int Function() _dStreamOutSize;
  final int Function(int) _isError;
  final Pointer<Utf8> Function(int) _getErrorName;

  _Zstd(DynamicLibrary lib)
      : _createDStream = lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('ZSTD_createDStream'),
        _freeDStream = lib.lookupFunction<Size Function(Pointer<Void>), int Function(Pointer<Void>)>('ZSTD_freeDStream'),
        _initDStream = lib.lookupFunction<Size Function(Pointer<Void>), int Function(Pointer<Void>)>('ZSTD_initDStream'),
        _decompressStream = lib.lookupFunction<Size Function(Pointer<Void>, Pointer<_OutBuffer>, Pointer<_InBuffer>),
            int Function(Pointer<Void>, Pointer<_OutBuffer>, Pointer<_InBuffer>)>('ZSTD_decompressStream'),
        _dStreamOutSize = lib.lookupFunction<Size Function(), int Function()>('ZSTD_DStreamOutSize'),
        _isError = lib.lookupFunction<UnsignedInt Function(Size), int Function(int)>('ZSTD_isError'),
        _getErrorName =
            lib.lookupFunction<Pointer<Utf8> Function(Size), Pointer<Utf8> Function(int)>('ZSTD_getErrorName');

  static _Zstd? _load() {
    final candidates = [
      if (Platform.environment['PROXYPIN_LIBZSTD'] != null) Platform.environment['PROXYPIN_LIBZSTD']!,
      if (Platform.isMacOS) ...['libzstd.dylib', '/opt/homebrew/lib/libzstd.dylib', '/usr/local/lib/libzstd.dylib'],
      if (Platform.isWindows) 'zstd.dll',
      'libzstd.so.1',
      'libzstd.so',
    ];
    for (final name in candidates) {
      try {
        return _Zstd(DynamicLibrary.open(name));
      } catch (_) {}
    }
    stderr.writeln('zstd: libzstd not found, zstd bodies stay encoded (set PROXYPIN_LIBZSTD)');
    return null;
  }

  List<int> decompress(List<int> bytes) {
    final stream = _createDStream();
    final input = calloc<_InBuffer>();
    final output = calloc<_OutBuffer>();
    final source = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    final chunkSize = _dStreamOutSize();
    final chunk = malloc<Uint8>(chunkSize);
    try {
      _check(_initDStream(stream));
      source.asTypedList(bytes.length).setAll(0, bytes);
      input.ref
        ..src = source.cast()
        ..size = bytes.length
        ..pos = 0;

      final result = BytesBuilder(copy: false);
      while (true) {
        output.ref
          ..dst = chunk.cast()
          ..size = chunkSize
          ..pos = 0;
        final ret = _check(_decompressStream(stream, output, input));
        if (output.ref.pos > 0) result.add(Uint8List.fromList(chunk.asTypedList(output.ref.pos)));
        final inputDone = input.ref.pos >= input.ref.size;
        // once all input is consumed, keep flushing only while the output buffer came back full
        if (inputDone && (ret == 0 || output.ref.pos < chunkSize)) break;
      }
      return result.takeBytes();
    } finally {
      _freeDStream(stream);
      calloc.free(input);
      calloc.free(output);
      malloc.free(source);
      malloc.free(chunk);
    }
  }

  int _check(int code) {
    if (_isError(code) != 0) throw FormatException('zstd: ${_getErrorName(code).toDartString()}');
    return code;
  }
}
