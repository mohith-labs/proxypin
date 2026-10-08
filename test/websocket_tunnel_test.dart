import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/network/handle/http_proxy_handle.dart';
import 'package:proxypin/network/http/codec.dart';

/// WebSocket tunnels through the proxy (Socket.IO / Engine.IO depend on all three):
///  - frames the server sends in the same TCP segment as its 101 response reach the client;
///  - the server closing the connection closes the client side too;
///  - after the client half-closes (as `ws` does after the closing handshake) the client still gets the FIN.
void main() {
  const int proxyPort = 19111;
  const String firstFrameText = 'hello-first';

  late Server proxy;
  late ServerSocket origin;

  /// Origin: `/first` answers the upgrade with 101 + one text frame in a single write, then closes once the
  /// client has closed; `/drop` answers 101 and closes right away (no close frame).
  Future<void> serveOrigin(Socket socket) async {
    final head = <int>[];
    late StreamSubscription<List<int>> sub;
    sub = socket.listen((data) async {
      head.addAll(data);
      final text = latin1.decode(head);
      if (!text.contains('\r\n\r\n')) return;
      sub.onData((_) {});
      final key = RegExp(r'sec-websocket-key: *(.+)\r\n', caseSensitive: false).firstMatch(text)!.group(1)!.trim();
      final accept = base64.encode(sha1.convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes);
      final response = latin1.encode('HTTP/1.1 101 Switching Protocols\r\n'
          'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n');
      if (RegExp(r'^GET \S*/first ').hasMatch(text)) {
        socket.add([...response, 0x81, firstFrameText.length, ...utf8.encode(firstFrameText)]);
      } else {
        socket.add(response);
        await socket.flush();
        await socket.close();
      }
    }, onDone: () => socket.close(), onError: (_) {}, cancelOnError: true);
  }

  setUpAll(() async {
    origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen(serveOrigin);

    final config = Configuration.fromJson({
      'enableSsl': false,
      'enableSocks5': false,
      'enableSystemProxy': false,
      'enabledHttp2': false,
    });
    config.port = proxyPort;
    proxy = Server(config);
    proxy.initChannel((channel) {
      channel.dispatcher.handle(
          HttpRequestCodec(), HttpResponseCodec(), HttpProxyChannelHandler(listener: null, interceptors: []));
    });
    await proxy.bind(proxyPort);
  });

  tearDownAll(() async {
    await proxy.stop();
    await origin.close();
  });

  /// Opens a WebSocket through the proxy with a raw socket; [received] collects everything the client reads and
  /// [done] completes when the proxy closes the client connection.
  Future<({Socket socket, List<int> received, Future<void> done})> upgrade(String path) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort);
    final received = <int>[];
    final done = Completer<void>();
    socket.listen(received.addAll,
        onDone: () => done.isCompleted ? null : done.complete(), onError: (_) => done.isCompleted ? null : done.complete());
    socket.write('GET http://127.0.0.1:${origin.port}$path HTTP/1.1\r\n'
        'Host: 127.0.0.1:${origin.port}\r\n'
        'Upgrade: websocket\r\nConnection: Upgrade\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n');
    await socket.flush();
    return (socket: socket, received: received, done: done.future);
  }

  Future<bool> waitFor(bool Function() condition) async {
    for (var i = 0; i < 60 && !condition(); i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return condition();
  }

  test('frames sent together with the 101 response reach the client', () async {
    final ws = await upgrade('/first');
    final arrived = await waitFor(() => latin1.decode(ws.received).contains(firstFrameText));
    ws.socket.destroy();
    expect(arrived, isTrue, reason: 'got: ${latin1.decode(ws.received)}');
  });

  test('client half-close still gets the FIN once the server closes', () async {
    final ws = await upgrade('/first');
    expect(await waitFor(() => latin1.decode(ws.received).contains(firstFrameText)), isTrue);
    await ws.socket.close(); // FIN; keep reading, like ws after the closing handshake
    await ws.done.timeout(const Duration(seconds: 3), onTimeout: () => fail('client never got the FIN'));
  });

  test('server closing the connection closes the client side', () async {
    final ws = await upgrade('/drop');
    await ws.done.timeout(const Duration(seconds: 3), onTimeout: () => fail('client connection stayed open'));
    ws.socket.destroy();
  });
}
