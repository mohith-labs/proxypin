import 'dart:typed_data';

import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/network/util/attribute_keys.dart';

/// Listener of the reverse proxy. Unlike the forward-proxy [Server] it never sniffs TLS ClientHellos or SOCKS
/// greetings and never raw-relays filtered hosts: every byte is plain HTTP that ReverseProxyChannelHandler routes
/// request by request.
class ReverseProxyServer extends Server {
  ReverseProxyServer(super.configuration, {super.listener});

  @override
  Future<void> onEvent(Uint8List data, ChannelContext channelContext, Channel channel) async {
    // upstream requests go through the configured external proxy, if any
    final externalProxy = configuration.externalProxy;
    channelContext.putAttribute(AttributeKeys.proxyInfo, externalProxy?.enabled == true ? externalProxy : null);
    channel.dispatcher.channelRead(channelContext, channel, data);
  }
}
