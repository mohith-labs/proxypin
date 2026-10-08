import 'dart:io';

Future<bool> reachable(String host, int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } on SocketException catch (_) {
    return false;
  }
}
