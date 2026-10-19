import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_manager.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_rule.dart';
import 'package:proxypin/server/auth/auth_store.dart';
import 'package:proxypin/server/auth/reverse_proxy_guard.dart';

/// A rule as it appears in `reverse_proxy.json`.
Map<String, dynamic> rule(String path, {String owner = '', String target = 'https://example.com'}) =>
    ReverseProxyRule(path: path, target: target, ownerId: owner).toJson();

Map<String, dynamic> config(List<Map<String, dynamic>> rules, {bool enabled = true}) =>
    {'enabled': enabled, 'rules': rules};

List<String> pathsOf(Map<String, dynamic> result) =>
    ((result['rules'] as List).cast<Map>()).map((e) => e['path'].toString()).toList();

Map<String, String> ownersOf(Map<String, dynamic> result) => {
      for (final e in (result['rules'] as List).cast<Map>())
        e['path'].toString(): (e['ownerId'] ?? '').toString(),
    };

AppUser user(String id, {String email = 'u@example.com', String prefix = ''}) =>
    AppUser(id: id, email: email, status: UserStatus.approved, pathPrefix: prefix);

void main() {
  // the admin is decided by the environment; without PROXYPIN_ADMIN_EMAIL set, nobody is admin
  final alice = user('alice-id', email: 'alice@example.com');

  group('path overlap', () {
    test('identical paths collide', () {
      expect(ReverseProxyManager.pathsOverlap('/a', '/a'), isTrue);
    });

    test('a path swallowing another collides', () {
      expect(ReverseProxyManager.pathsOverlap('/a', '/a/b'), isTrue);
      expect(ReverseProxyManager.pathsOverlap('/a/b', '/a'), isTrue);
    });

    test('root collides with everything', () {
      expect(ReverseProxyManager.pathsOverlap('/', '/anything'), isTrue);
    });

    test('siblings and partial names do not collide', () {
      expect(ReverseProxyManager.pathsOverlap('/a', '/b'), isFalse);
      // /apix must not be treated as being under /api
      expect(ReverseProxyManager.pathsOverlap('/api', '/apix'), isFalse);
      expect(ReverseProxyManager.pathsOverlap('/user1/test', '/user2/test'), isFalse);
    });
  });

  group('visibility', () {
    test('a user sees only their own rules', () {
      final manager = ReverseProxyManager.forTest([
        ReverseProxyRule(path: '/a', target: 'https://a.com', ownerId: 'alice-id'),
        ReverseProxyRule(path: '/b', target: 'https://b.com', ownerId: 'bob-id'),
      ]);
      final visible = manager.visibleTo(userId: 'alice-id', isAdmin: false);
      expect(visible.map((e) => e.path), ['/a']);
    });

    test('an admin sees every rule, including unowned ones', () {
      final manager = ReverseProxyManager.forTest([
        ReverseProxyRule(path: '/a', target: 'https://a.com', ownerId: 'alice-id'),
        ReverseProxyRule(path: '/legacy', target: 'https://l.com'), // created before ownership existed
      ]);
      expect(manager.visibleTo(userId: 'admin-id', isAdmin: true).length, 2);
    });

    test('unowned rules are invisible to ordinary users', () {
      final manager = ReverseProxyManager.forTest([
        ReverseProxyRule(path: '/legacy', target: 'https://l.com'),
      ]);
      expect(manager.visibleTo(userId: 'alice-id', isAdmin: false), isEmpty);
    });
  });

  group('merge: other users are protected', () {
    test("a user's write keeps rules they cannot see", () {
      // alice's console only knows /a, so her save must not delete bob's /b
      final result = ReverseProxyGuard.merge(
        current: config([rule('/a', owner: 'alice-id'), rule('/b', owner: 'bob-id')]),
        submitted: config([rule('/a', owner: 'alice-id')]),
        user: alice,
      );
      expect(pathsOf(result), containsAll(['/a', '/b']));
    });

    test('deleting a rule removes only the caller’s own', () {
      final result = ReverseProxyGuard.merge(
        current: config([rule('/a', owner: 'alice-id'), rule('/b', owner: 'bob-id')]),
        submitted: config([]), // alice deleted her only rule
        user: alice,
      );
      expect(pathsOf(result), ['/b']);
    });

    test('a user cannot claim somebody else’s rule', () {
      expect(
        () => ReverseProxyGuard.merge(
          current: config([rule('/b', owner: 'bob-id')]),
          submitted: config([rule('/b', owner: 'bob-id')]), // alice tries to edit bob's rule
          user: alice,
        ),
        throwsA(isA<RuleRejected>()),
      );
    });

    test('a user cannot forge an owner id', () {
      expect(
        () => ReverseProxyGuard.merge(
          current: config([]),
          submitted: config([rule('/x', owner: 'bob-id')]),
          user: alice,
        ),
        throwsA(isA<RuleRejected>()),
      );
    });

    test('a new rule is stamped with the caller', () {
      final result = ReverseProxyGuard.merge(
        current: config([]),
        submitted: config([rule('/new')]),
        user: alice,
      );
      expect(ownersOf(result)['/new'], 'alice-id');
    });

    test('an unowned rule cannot be taken over by a user', () {
      expect(
        () => ReverseProxyGuard.merge(
          current: config([rule('/legacy')]), // admin-owned by convention
          submitted: config([rule('/legacy')]),
          user: alice,
        ),
        throwsA(isA<RuleRejected>()),
      );
    });
  });

  group('merge: conflicts', () {
    test('a path already used by another user is rejected', () {
      expect(
        () => ReverseProxyGuard.merge(
          current: config([rule('/shared', owner: 'bob-id')]),
          submitted: config([rule('/shared')]),
          user: alice,
        ),
        throwsA(isA<RuleRejected>()),
      );
    });

    test('a path nested under another user’s path is rejected', () {
      expect(
        () => ReverseProxyGuard.merge(
          current: config([rule('/api', owner: 'bob-id')]),
          submitted: config([rule('/api/v2')]),
          user: alice,
        ),
        throwsA(isA<RuleRejected>()),
      );
    });

    test('a sibling path is accepted', () {
      final result = ReverseProxyGuard.merge(
        current: config([rule('/api', owner: 'bob-id')]),
        submitted: config([rule('/web')]),
        user: alice,
      );
      expect(pathsOf(result), containsAll(['/api', '/web']));
    });

    test('editing a rule without moving it is allowed', () {
      final result = ReverseProxyGuard.merge(
        current: config([rule('/a', owner: 'alice-id', target: 'https://old.com')]),
        submitted: config([rule('/a', owner: 'alice-id', target: 'https://new.com')]),
        user: alice,
      );
      final saved = (result['rules'] as List).cast<Map>().firstWhere((e) => e['path'] == '/a');
      expect(saved['target'], 'https://new.com');
    });
  });

  group('prefix', () {
    final prefixed = user('alice-id', email: 'alice@example.com', prefix: '/user1');

    test('a prefix is normalized', () {
      expect(AppUser.normalizePrefix('user1'), '/user1');
      expect(AppUser.normalizePrefix('/user1/'), '/user1');
      expect(AppUser.normalizePrefix('/'), '');
      expect(AppUser.normalizePrefix(''), '');
    });

    test('a new path is placed under the prefix', () {
      expect(prefixed.applyPrefix('/path'), '/user1/path');
      expect(prefixed.applyPrefix('path'), '/user1/path');
    });

    test('a user without a prefix keeps their path', () {
      expect(alice.applyPrefix('/path'), '/path');
    });

    test('merge places a new rule under the prefix', () {
      final result = ReverseProxyGuard.merge(
        current: config([]),
        submitted: config([rule('/path')]),
        user: prefixed,
      );
      expect(pathsOf(result), ['/user1/path']);
    });

    test('two users with different prefixes may use the same path name', () {
      final bobPrefixed = user('bob-id', email: 'bob@example.com', prefix: '/user2');
      var state = ReverseProxyGuard.merge(
        current: config([]),
        submitted: config([rule('/test')]),
        user: prefixed,
      );
      state = ReverseProxyGuard.merge(
        current: state,
        submitted: config([rule('/test')]),
        user: bobPrefixed,
      );
      expect(pathsOf(state), containsAll(['/user1/test', '/user2/test']));
    });

    test('any new path a prefixed user asks for lands under their prefix', () {
      // they cannot escape the prefix by typing an absolute-looking path
      final result = ReverseProxyGuard.merge(
        current: config([]),
        submitted: config([rule('/elsewhere', owner: 'alice-id')]),
        user: prefixed,
      );
      expect(pathsOf(result), ['/user1/elsewhere']);
    });

    test('a route left outside the prefix is pulled under it on the next save', () {
      // /legacy predates the prefix; re-saving it moves it into her namespace rather than leaving a
      // route of hers outside it
      final result = ReverseProxyGuard.merge(
        current: config([rule('/legacy', owner: 'alice-id')]),
        submitted: config([rule('/legacy', owner: 'alice-id')]),
        user: prefixed,
      );
      expect(pathsOf(result), ['/user1/legacy']);
    });

    test('a prefixed user editing their own route does not double the prefix', () {
      final result = ReverseProxyGuard.merge(
        current: config([rule('/user1/a', owner: 'alice-id', target: 'https://old.com')]),
        submitted: config([rule('/user1/a', owner: 'alice-id', target: 'https://new.com')]),
        user: prefixed,
      );
      expect(pathsOf(result), ['/user1/a']);
    });

    test('a prefixed user cannot take a path owned by somebody else inside their own prefix', () {
      // defence in depth: an attacker-shaped payload naming a path already under /user1
      expect(
        () => ReverseProxyGuard.merge(
          current: config([rule('/user1/taken', owner: 'bob-id')]),
          submitted: config([rule('/user1/taken')]),
          user: prefixed,
        ),
        throwsA(isA<RuleRejected>()),
      );
    });
  });

  group('reprefix', () {
    final prefixed = user('alice-id', email: 'alice@example.com', prefix: '/user1');

    test('existing rules move to the new prefix', () {
      final result = ReverseProxyGuard.reprefix(
        current: config([rule('/user1/a', owner: 'alice-id'), rule('/user1/b', owner: 'alice-id')]),
        user: prefixed,
        prefix: '/mohith',
      );
      expect(pathsOf(result), ['/mohith/a', '/mohith/b']);
    });

    test('other users’ rules are untouched', () {
      final result = ReverseProxyGuard.reprefix(
        current: config([rule('/user1/a', owner: 'alice-id'), rule('/user2/b', owner: 'bob-id')]),
        user: prefixed,
        prefix: '/mohith',
      );
      expect(pathsOf(result), containsAll(['/mohith/a', '/user2/b']));
    });

    test('clearing the prefix restores bare paths', () {
      final result = ReverseProxyGuard.reprefix(
        current: config([rule('/user1/a', owner: 'alice-id')]),
        user: prefixed,
        prefix: '',
      );
      expect(pathsOf(result), ['/a']);
    });

    test('a move that would collide is rejected', () {
      expect(
        () => ReverseProxyGuard.reprefix(
          current: config([rule('/user1/a', owner: 'alice-id'), rule('/taken/a', owner: 'bob-id')]),
          user: prefixed,
          prefix: '/taken',
        ),
        throwsA(isA<RuleRejected>()),
      );
    });

    test('adopting a prefix moves a previously bare path', () {
      final bare = user('alice-id', email: 'alice@example.com');
      final result = ReverseProxyGuard.reprefix(
        current: config([rule('/a', owner: 'alice-id')]),
        user: bare,
        prefix: '/user1',
      );
      expect(pathsOf(result), ['/user1/a']);
    });
  });

  group('retention settings', () {
    test('zero hours disables the sweep', () {
      expect(AuthSettings(retentionHours: 0).retention, isNull);
    });

    test('a positive window is a duration', () {
      expect(AuthSettings(retentionHours: 24 * 7).retention, const Duration(days: 7));
    });

    test('the window survives a round trip', () {
      final restored = AuthSettings.fromJson(AuthSettings(retentionHours: 72).toJson());
      expect(restored.retentionHours, 72);
    });
  });
}
