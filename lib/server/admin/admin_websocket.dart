import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/channel_dispatcher.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/network/util/logger.dart';

/// Server side of a WebSocket opened by the web UI, running directly on the ProxyPin [Channel] that received
/// the upgrade request (UI and reverse-proxy traffic share one listener, so dart:io's HttpServer is not used).
class AdminWebSocket {
  static const _guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  final Channel channel;
  final ChannelContext channelContext;
  final WebSocketDecoder _decoder = WebSocketDecoder();
  final List<int> _fragments = [];
  Timer? _pingTimer;
  bool _closed = false;

  /// Text messages from the browser.
  void Function(String message)? onMessage;

  /// Called once when the connection ends.
  void Function()? onClose;

  AdminWebSocket._(this.channel, this.channelContext);

  static bool isUpgrade(HttpRequest request) =>
      request.headers.get('Upgrade')?.toLowerCase() == 'websocket' &&
      (request.headers.get('Connection')?.toLowerCase().contains('upgrade') ?? false);

  /// Completes the handshake and takes over the channel.
  static Future<AdminWebSocket?> upgrade(ChannelContext channelContext, Channel channel, HttpRequest request) async {
    final key = request.headers.get('Sec-WebSocket-Key');
    if (key == null || !isUpgrade(request)) return null;

    final accept = base64Encode(sha1.convert(utf8.encode('$key$_guid')).bytes);
    final response = HttpResponse(HttpStatus(101, 'Switching Protocols'))
      ..headers.set('Upgrade', 'websocket')
      ..headers.set('Connection', 'Upgrade')
      ..headers.set('Sec-WebSocket-Accept', accept);
    await channel.write(channelContext, response);

    final socket = AdminWebSocket._(channel, channelContext);
    channel.dispatcher.channelHandle(RawCodec(), _AdminWebSocketHandler(socket));
    socket._pingTimer = Timer.periodic(const Duration(seconds: 25), (_) => socket._send(0x9, const []));
    return socket;
  }

  bool get isClosed => _closed || channel.isClosed;

  void sendText(String text) => _send(0x1, utf8.encode(text));

  void sendJson(Object message) => sendText(jsonEncode(message));

  void close([int code = 1000]) {
    if (_closed) return;
    _send(0x8, [code >> 8, code & 0xff]);
    _finish();
    channel.close();
  }

  void _send(int opcode, List<int> payload) {
    if (isClosed) return;
    final header = BytesBuilder(copy: false)..addByte(0x80 | opcode); // FIN, unmasked (server -> client)
    final length = payload.length;
    if (length < 126) {
      header.addByte(length);
    } else if (length < 65536) {
      header
        ..addByte(126)
        ..add([length >> 8, length & 0xff]);
    } else {
      final bytes = ByteData(8)..setUint64(0, length);
      header
        ..addByte(127)
        ..add(bytes.buffer.asUint8List());
    }
    header.add(payload);
    channel.writeBytes(header.takeBytes());
  }

  void _onData(Uint8List data) {
    var frame = _decoder.decode(data);
    while (frame != null) {
      _onFrame(frame);
      if (_closed) return;
      frame = _decoder.decode(Uint8List(0));
    }
  }

  void _onFrame(WebSocketFrame frame) {
    switch (frame.opcode) {
      case 0x8: // close
        _send(0x8, frame.payloadData.length >= 2 ? frame.payloadData.sublist(0, 2) : const []);
        _finish();
        channel.close();
        return;
      case 0x9: // ping
        _send(0xA, frame.payloadData);
        return;
      case 0xA: // pong
        return;
    }

    _fragments.addAll(frame.payloadData);
    if (!frame.fin) return;
    final payload = List<int>.of(_fragments);
    _fragments.clear();
    try {
      onMessage?.call(utf8.decode(payload, allowMalformed: true));
    } catch (e, t) {
      logger.e('admin websocket message error', error: e, stackTrace: t);
    }
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel();
    onClose?.call();
  }
}

class _AdminWebSocketHandler extends ChannelHandler<Uint8List> {
  final AdminWebSocket socket;

  _AdminWebSocketHandler(this.socket);

  @override
  Future<void> channelRead(ChannelContext channelContext, Channel channel, Uint8List msg) async => socket._onData(msg);

  @override
  void channelInactive(ChannelContext channelContext, Channel channel) => socket._finish();

  @override
  void exceptionCaught(ChannelContext channelContext, Channel channel, dynamic error, {StackTrace? trace}) {
    socket._finish();
    channel.close();
  }
}
