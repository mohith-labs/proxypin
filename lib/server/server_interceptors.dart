import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/components/interceptor.dart';
import 'package:proxypin/network/http/http.dart';

/// Skips an interceptor while capturing is paused, so a stopped ProxyPin forwards traffic untouched (the same
/// as switching the desktop proxy off, except the reverse-proxied app keeps working).
class CaptureAwareInterceptor extends Interceptor {
  final Interceptor delegate;
  final bool Function() active;

  CaptureAwareInterceptor(this.delegate, this.active);

  @override
  int get priority => delegate.priority;

  @override
  Future<HostAndPort> preConnect(HostAndPort hostAndPort) =>
      active() ? delegate.preConnect(hostAndPort) : Future.value(hostAndPort);

  @override
  Future<HttpResponse?> execute(HttpRequest request) => active() ? delegate.execute(request) : Future.value(null);

  @override
  Future<HttpRequest?> onRequest(HttpRequest request) =>
      active() ? delegate.onRequest(request) : Future.value(request);

  @override
  Future<HttpResponse?> onResponse(HttpRequest request, HttpResponse response) =>
      active() ? delegate.onResponse(request, response) : Future.value(response);

  @override
  Future<void> onError(HttpRequest? request, error, StackTrace? stackTrace) =>
      active() ? delegate.onError(request, error, stackTrace) : Future.value();
}
