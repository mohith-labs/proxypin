import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_rule.dart';

void main() {
  group('ReverseProxyRule path matching', () {
    test('matches on segment boundaries', () {
      final rule = ReverseProxyRule(path: '/proxy', target: 'https://example.com');
      expect(rule.matches('/proxy'), isTrue);
      expect(rule.matches('/proxy/'), isTrue);
      expect(rule.matches('/proxy/users'), isTrue);
      expect(rule.matches('/proxyfoo'), isFalse);
      expect(rule.matches('/'), isFalse);
    });

    test('root rule matches everything', () {
      final rule = ReverseProxyRule(path: '/', target: 'https://example.com');
      expect(rule.matches('/'), isTrue);
      expect(rule.matches('/anything/else'), isTrue);
    });

    test('normalizes the configured path', () {
      expect(ReverseProxyRule(path: 'proxy/', target: 'https://e.com').path, '/proxy');
      expect(ReverseProxyRule(path: '', target: 'https://e.com').path, '/');
      expect(ReverseProxyRule(path: ' /a/b// ', target: 'https://e.com').path, '/a/b');
    });
  });

  group('ReverseProxyRule upstream mapping', () {
    test('strip prefix (default)', () {
      final rule = ReverseProxyRule(path: '/proxy', target: 'https://example.com');
      expect(rule.upstreamUri('/proxy'), '/');
      expect(rule.upstreamUri('/proxy/'), '/');
      expect(rule.upstreamUri('/proxy/users'), '/users');
      expect(rule.upstreamUri('/proxy/users?id=1&x=%20'), '/users?id=1&x=%20');
      expect(rule.upstreamUri('/proxy?q=1'), '/?q=1');
    });

    test('strip prefix with a target base path', () {
      final rule = ReverseProxyRule(path: '/api', target: 'https://example.com/v2/');
      expect(rule.upstreamUri('/api'), '/v2');
      expect(rule.upstreamUri('/api/users'), '/v2/users');
      expect(rule.upstreamUri('/api/users/?a=b'), '/v2/users/?a=b');
    });

    test('keep prefix', () {
      final rule = ReverseProxyRule(path: '/proxy', target: 'https://example.com', stripPrefix: false);
      expect(rule.upstreamUri('/proxy'), '/proxy');
      expect(rule.upstreamUri('/proxy/users?x=1'), '/proxy/users?x=1');

      final based = ReverseProxyRule(path: '/proxy', target: 'https://example.com/base', stripPrefix: false);
      expect(based.upstreamUri('/proxy/users'), '/base/proxy/users');
    });

    test('root rule forwards the path unchanged', () {
      final rule = ReverseProxyRule(path: '/', target: 'http://localhost:3000');
      expect(rule.upstreamUri('/'), '/');
      expect(rule.upstreamUri('/a/b?c=d'), '/a/b?c=d');
    });
  });

  group('ReverseProxyRule reverse mapping', () {
    test('maps upstream paths back onto the proxy prefix', () {
      final rule = ReverseProxyRule(path: '/proxy', target: 'https://example.com');
      expect(rule.proxyPathFor('/login?next=%2F'), '/proxy/login?next=%2F');
      expect(rule.proxyPathFor('/'), '/proxy/');
      expect(rule.proxyPathFor(''), '/proxy');
    });

    test('respects the target base path', () {
      final rule = ReverseProxyRule(path: '/api', target: 'https://example.com/v2');
      expect(rule.proxyPathFor('/v2/users'), '/api/users');
      expect(rule.proxyPathFor('/v2'), '/api');
      expect(rule.proxyPathFor('/other'), isNull);
    });

    test('keep prefix only maps paths the rule can reach', () {
      final rule = ReverseProxyRule(path: '/proxy', target: 'https://example.com', stripPrefix: false);
      expect(rule.proxyPathFor('/proxy/x'), '/proxy/x');
      expect(rule.proxyPathFor('/elsewhere'), isNull);
    });

    test('round trips', () {
      final rule = ReverseProxyRule(path: '/svc', target: 'https://example.com/base');
      for (final path in ['/svc', '/svc/a', '/svc/a/b?c=d']) {
        expect(rule.proxyPathFor(rule.upstreamUri(path)), path);
      }
    });
  });

  group('ReverseProxyRule target', () {
    test('host header and host/port', () {
      expect(ReverseProxyRule(path: '/', target: 'https://example.com').targetHostHeader, 'example.com');
      expect(ReverseProxyRule(path: '/', target: 'http://example.com:8080/x').targetHostHeader, 'example.com:8080');
      final hostAndPort = ReverseProxyRule(path: '/', target: 'https://example.com').targetHostAndPort;
      expect(hostAndPort.isSsl(), isTrue);
      expect(hostAndPort.port, 443);
      expect(hostAndPort.domain, 'https://example.com');
    });

    test('validation', () {
      expect(ReverseProxyRule.validateTarget('https://example.com'), isNull);
      expect(ReverseProxyRule.validateTarget('http://10.0.0.1:8080/base'), isNull);
      expect(ReverseProxyRule.validateTarget('example.com'), isNotNull);
      expect(ReverseProxyRule.validateTarget('ftp://example.com'), isNotNull);
      expect(ReverseProxyRule.validateTarget('https://example.com/?a=1'), isNotNull);
    });

    test('json round trip', () {
      final rule = ReverseProxyRule(
          name: 'n', path: '/p', target: 'https://e.com', stripPrefix: false, preserveHost: true, rewriteResponse: false);
      final copy = ReverseProxyRule.fromJson(rule.toJson());
      expect(copy.toJson(), rule.toJson());
    });
  });
}
