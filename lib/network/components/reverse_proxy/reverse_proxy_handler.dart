import 'dart:convert';

import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/handle/http_proxy_handle.dart';
import 'package:proxypin/network/handle/relay_handle.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/attribute_keys.dart';
import 'package:proxypin/network/util/logger.dart';

import 'reverse_proxy_manager.dart';
import 'reverse_proxy_rule.dart';

/// Serves requests that are not reverse-proxied (the web UI); returns true when it answered the request.
typedef LocalRequestHandler = Future<bool> Function(ChannelContext channelContext, Channel channel, HttpRequest request);

/// Reverse-proxy request handling: every request is routed on its own (a keep-alive connection may hit several
/// rules), rewritten to the rule's target, then run through the normal ProxyPin pipeline (interceptors, capture,
/// breakpoints, scripts...).
class ReverseProxyChannelHandler extends HttpProxyChannelHandler {
  /// JSON-safe description of the route a captured request took (shown in the UI).
  static const String routeAttribute = 'reverseProxy';

  /// The live [ReverseProxyRule] (engine-private, not serialized).
  static const String ruleAttribute = '_reverseProxyRule';

  static const String _targetKey = 'REVERSE_PROXY_TARGET';
  static const String _inflightKey = 'REVERSE_PROXY_INFLIGHT';

  final LocalRequestHandler? localHandler;

  ReverseProxyChannelHandler({super.listener, required super.interceptors, this.localHandler});

  @override
  void channelActive(ChannelContext context, Channel channel) {
    context.relayHandlerFactory =
        (from, to) => identical(from, context.clientChannel) ? _ClientRelayGuard(to) : RelayHandler(to);
  }

  @override
  Future<void> channelRead(ChannelContext channelContext, Channel channel, HttpRequest msg) async {
    try {
      if (localHandler != null && await localHandler!(channelContext, channel, msg)) {
        // UI/API exchanges are not traffic: never report them if the connection fails later
        channelContext.currentRequest = null;
        return;
      }
      await _route(channelContext, channel, msg);
    } catch (error, trace) {
      exceptionCaught(channelContext, channel, error, trace: trace);
    }
  }

  Future<void> _route(ChannelContext channelContext, Channel channel, HttpRequest request) async {
    final pathAndQuery = clientPathAndQuery(request.uri);
    final path = pathAndQuery.split('?').first;

    final manager = await ReverseProxyManager.instance;
    final rule = manager.match(path);
    if (rule == null) {
      await _noRoute(channelContext, channel, request, path);
      return;
    }

    if (request.method == HttpMethod.connect) {
      await _respond(channelContext, channel, request, 405, 'Method Not Allowed',
          'ProxyPin runs as a reverse proxy here; CONNECT is not supported.');
      return;
    }

    _rewrite(channelContext, request, rule, pathAndQuery);
    _prepareUpstream(channelContext, channel, request.hostAndPort!);
    channelContext.putAttribute(_inflightKey, true);
    await forward(channelContext, channel, request);
  }

  /// Path and query of the client request (absolute-form URIs, e.g. from clients configured to use this as a
  /// forward proxy, are reduced to their path).
  static String clientPathAndQuery(String uri) {
    if (uri == '*') return '/';
    if (HostAndPort.startsWithScheme(uri)) {
      final parsed = Uri.tryParse(uri);
      if (parsed != null) {
        final path = parsed.path.isEmpty ? '/' : parsed.path;
        return parsed.hasQuery ? '$path?${parsed.query}' : path;
      }
    }
    return uri.startsWith('/') ? uri : '/$uri';
  }

  void _rewrite(ChannelContext channelContext, HttpRequest request, ReverseProxyRule rule, String pathAndQuery) {
    final target = rule.targetHostAndPort;
    final clientHost = request.headers.host;
    // behind a TLS-terminating proxy (e.g. OrbStack's https://*.orb.local) the client used https
    final secure = request.headers.get('X-Forwarded-Proto')?.split(',').first.trim().toLowerCase() == 'https';
    final websocket = request.headers.get('Upgrade')?.toLowerCase() == 'websocket';

    var upstreamUri = rule.upstreamUri(pathAndQuery);
    // a plain-http target behind an external proxy needs the absolute-form request line
    if (!target.isSsl() && channelContext.getAttribute(AttributeKeys.proxyInfo) != null) {
      upstreamUri = '${target.domain}$upstreamUri';
    }

    request.hostAndPort = target;
    request.uri = upstreamUri;
    if (!rule.preserveHost) request.headers.host = rule.targetHostHeader;

    request.attributes[routeAttribute] = {
      'name': rule.name,
      'path': rule.path,
      'target': rule.target,
      'clientUri': pathAndQuery,
      if (clientHost != null) 'clientHost': clientHost,
      'clientScheme': websocket ? (secure ? 'wss' : 'ws') : (secure ? 'https' : 'http'),
    };
    request.attributes[ruleAttribute] = rule;
  }

  /// Reuses the connection's upstream channel only when it goes to the same target.
  void _prepareUpstream(ChannelContext channelContext, Channel client, HostAndPort target) {
    channelContext.host = target.copyWith();
    final current = channelContext.serverChannel;
    if (current != null) {
      final currentTarget = channelContext.getAttribute<HostAndPort>(_targetKey);
      if (current.isClosed || currentTarget != target) {
        _detachUpstream(channelContext, current);
      } else {
        // the client->upstream link is dropped between exchanges (see ReverseResponseProxyHandler)
        channelContext.putAttribute(client.id, current);
      }
    }
    channelContext.putAttribute(_targetKey, target);
  }

  static void _detachUpstream(ChannelContext channelContext, Channel upstream) {
    upstream.dispatcher.handler = _DetachedHandler();
    channelContext.putAttribute(upstream.id, null);
    final client = channelContext.clientChannel;
    if (client != null) channelContext.putAttribute(client.id, null);
    if (identical(channelContext.serverChannel, upstream)) channelContext.serverChannel = null;
    upstream.close();
  }

  @override
  bool upstreamSecure(Channel clientChannel, HttpRequest request) => request.hostAndPort?.isSsl() == true;

  @override
  Future<Channel> connectRemote(ChannelContext channelContext, Channel clientChannel, HostAndPort connectHost) {
    final handler = ReverseResponseProxyHandler(clientChannel, interceptors, listener: listener);
    return channelContext.connectServerChannel(connectHost, handler);
  }

  Future<void> _noRoute(ChannelContext channelContext, Channel channel, HttpRequest request, String path) async {
    if (path == '/' && (request.method == HttpMethod.get || request.method == HttpMethod.head)) {
      final response = HttpResponse(HttpStatus(302, 'Found'), protocolVersion: _version(request))
        ..headers.set('Location', '/__proxypin/')
        ..headers.contentLength = 0
        ..body = const [];
      await channel.write(channelContext, response);
      return;
    }

    final rules = ReverseProxyManager.instanceOrNull?.rules.where((e) => e.enabled).map((e) => e.path).toList() ?? [];
    final message = 'ProxyPin: no reverse proxy rule matches $path.\n'
        '${rules.isEmpty ? 'No rules are configured yet.' : 'Configured paths: ${rules.join(', ')}'}\n'
        'Manage rules at /__proxypin/';
    // Not captured: nothing was proxied, and browsers send plenty of such requests to the console's origin
    // (favicons, extensions, probes) that would only clutter the request list.
    log.d('[${channel.id}] no reverse proxy rule for ${request.method.name} $path');
    await _respond(channelContext, channel, request, 404, 'Not Found', message);
  }

  static String _version(HttpRequest request) =>
      request.protocolVersion == 'HTTP/2' ? HttpMessage.http1Version : request.protocolVersion;

  static Future<HttpResponse> _respond(ChannelContext channelContext, Channel channel, HttpRequest request, int code,
      String reason, String message,
      {bool close = false}) async {
    final body = utf8.encode('$message\n');
    final response = HttpResponse(HttpStatus(code, reason), protocolVersion: _version(request))
      ..headers.contentType = 'text/plain; charset=utf-8'
      ..headers.contentLength = body.length
      ..body = request.method == HttpMethod.head ? null : body
      ..request = request;
    if (close) {
      response.headers.set('Connection', 'close');
      await channel.writeAndClose(channelContext, response);
    } else {
      await channel.write(channelContext, response);
    }
    return response;
  }

  @override
  void exceptionCaught(ChannelContext channelContext, Channel channel, error, {StackTrace? trace}) {
    final request = channelContext.currentRequest;
    final inflight = channelContext.getAttribute(_inflightKey) == true;
    if (!inflight || request == null || !request.attributes.containsKey(routeAttribute)) {
      // idle keep-alive resets, aborted UI connections, malformed requests: nothing was proxied
      log.d('[${channel.id}] connection error: $error');
      channel.close();
      return;
    }
    _replyBadGateway(channelContext, error);
    super.exceptionCaught(channelContext, channel, error, trace: trace);
  }

  /// A reverse proxy answers failed upstream exchanges with 502 instead of dropping the client connection.
  static void _replyBadGateway(ChannelContext channelContext, dynamic error) {
    if (channelContext.getAttribute(_inflightKey) != true) return;
    channelContext.putAttribute(_inflightKey, null);
    final client = channelContext.clientChannel;
    final request = channelContext.currentRequest;
    if (client == null || client.isClosed || request == null) return;
    _respond(channelContext, client, request, 502, 'Bad Gateway', 'ProxyPin: upstream request failed: $error',
            close: true)
        .catchError((e) {
      logger.w('reverse proxy: cannot send 502: $e');
      return HttpResponse(HttpStatus.badGateway);
    });
  }
}

/// Upstream side of a reverse-proxied connection.
class ReverseResponseProxyHandler extends HttpResponseProxyHandler {
  ReverseResponseProxyHandler(super.clientChannel, super.interceptors, {super.listener});

  @override
  Future<void> channelRead(ChannelContext channelContext, Channel channel, HttpResponse msg) async {
    await super.channelRead(channelContext, channel, msg);
    if (msg.status.code >= 200) {
      channelContext.putAttribute(ReverseProxyChannelHandler._inflightKey, null);
      // unlink client->upstream until the next exchange: a large next request must be buffered and rewritten,
      // not raw-relayed to this upstream (ChannelDispatcher relays oversized bodies to the linked channel)
      channelContext.putAttribute(clientChannel.id, null);
    }
  }

  @override
  void channelInactive(ChannelContext channelContext, Channel channel) {
    if (channelContext.getAttribute(ReverseProxyChannelHandler._inflightKey) == true) {
      ReverseProxyChannelHandler._replyBadGateway(channelContext, 'upstream closed the connection');
      return;
    }
    // an idle keep-alive upstream went away: forget it, keep the client connection open
    channelContext.putAttribute(channel.id, null);
    channelContext.putAttribute(clientChannel.id, null);
    if (identical(channelContext.serverChannel, channel)) channelContext.serverChannel = null;
  }

  @override
  void exceptionCaught(ChannelContext channelContext, Channel channel, error, {StackTrace? trace}) {
    ReverseProxyChannelHandler._replyBadGateway(channelContext, error);
    super.exceptionCaught(channelContext, channel, error, trace: trace);
  }
}

/// Swallows events of an upstream channel that was replaced by a connection to another target.
class _DetachedHandler extends ChannelHandler<Object> {
  @override
  void exceptionCaught(ChannelContext channelContext, Channel channel, dynamic error, {StackTrace? trace}) {
    channel.close();
  }
}

/// Client side of a raw relay. The relay was set up for one oversized response; a new request on the same
/// connection could belong to another rule, so close and let the client retry on a fresh connection.
class _ClientRelayGuard extends ChannelHandler<Object> {
  final Channel upstream;

  _ClientRelayGuard(this.upstream);

  @override
  Future<void> channelRead(ChannelContext channelContext, Channel channel, Object msg) async {
    upstream.close();
    channel.close();
  }

  @override
  void channelInactive(ChannelContext channelContext, Channel channel) {
    upstream.close();
  }
}
