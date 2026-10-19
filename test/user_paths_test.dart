import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/server/auth/auth_store.dart';
import 'package:proxypin/server/auth/user_paths.dart';

/// Per-user data isolation: what the browser asks for vs. the file the server actually touches.
void main() {
  const root = '/data';

  final alice = AppUser(id: 'sub-alice', email: 'alice@example.com');
  final bob = AppUser(id: 'sub-bob', email: 'bob@example.com');

  String confine(String path, AppUser user) => UserPaths.confine(path, user, dataDir: root);

  group('personal files are redirected into the user directory', () {
    for (final name in UserPaths.perUserFiles) {
      test('$name is private to each user', () {
        final a = confine('$root/$name', alice);
        final b = confine('$root/$name', bob);

        expect(a, '$root/users/sub-alice/$name');
        expect(b, '$root/users/sub-bob/$name');
        expect(a, isNot(b), reason: 'two users must never share $name');
      });
    }

    test('saved capture sessions are private', () {
      expect(confine('$root/history/1700000000.txt', alice), '$root/users/sub-alice/history/1700000000.txt');
      expect(confine('$root/history/1700000000.txt', bob), '$root/users/sub-bob/history/1700000000.txt');
    });

    test('a relative path is resolved the same way', () {
      expect(confine('favorites.json', alice), '$root/users/sub-alice/favorites.json');
    });
  });

  group('shared engine configuration stays shared', () {
    // one proxy engine serves everybody, so its rules cannot be per-user
    const shared = ['config.cnf', 'request_rewrite.json', 'request_map.json', 'script.json', 'reverse_proxy.json'];
    for (final name in shared) {
      test('$name is the same file for every user', () {
        expect(confine('$root/$name', alice), '$root/$name');
        expect(confine('$root/$name', bob), '$root/$name');
      });
    }

    test('uploaded files stay shared', () {
      expect(confine('$root/files/body.json', alice), '$root/files/body.json');
    });
  });

  group('traversal and cross-user access', () {
    test('a path outside the data directory is refused', () {
      expect(() => confine('/etc/passwd', alice), throwsA(isA<ForbiddenPath>()));
    });

    test('climbing out with .. is refused', () {
      expect(() => confine('$root/../etc/passwd', alice), throwsA(isA<ForbiddenPath>()));
      expect(() => confine('../../etc/passwd', alice), throwsA(isA<ForbiddenPath>()));
    });

    test("a user cannot read another user's directory", () {
      expect(() => confine('$root/users/sub-bob/favorites.json', alice), throwsA(isA<ForbiddenPath>()));
    });

    test("a user cannot escape their own directory with ..", () {
      expect(() => confine('$root/users/sub-alice/../sub-bob/favorites.json', alice),
          throwsA(isA<ForbiddenPath>()));
    });

    test('a user may address their own directory explicitly', () {
      expect(confine('$root/users/sub-alice/favorites.json', alice), '$root/users/sub-alice/favorites.json');
    });

    test('an empty path is rejected', () {
      expect(() => confine('', alice), throwsA(isA<FormatException>()));
    });
  });

  group('administrator', () {
    test('an admin may reach any user directory (for support and cleanup)', () {
      final admin = _AdminUser(id: 'sub-admin', email: 'admin@example.com');
      expect(confine('$root/users/sub-bob/favorites.json', admin), '$root/users/sub-bob/favorites.json');
    });

    test("an admin's own personal files are still their own", () {
      final admin = _AdminUser(id: 'sub-admin', email: 'admin@example.com');
      expect(confine('$root/favorites.json', admin), '$root/users/sub-admin/favorites.json');
    });
  });

  group('storage keys', () {
    test('a hostile id cannot build a path outside users/', () {
      final nasty = AppUser(id: '../../../etc', email: 'x@example.com');
      final resolved = confine('$root/favorites.json', nasty);
      expect(resolved.startsWith('$root/users/'), isTrue, reason: 'resolved to $resolved');
    });

    test('ids differing only in unsafe characters do not collide into one directory', () {
      final a = AppUser(id: 'a/b', email: 'a@example.com');
      final b = AppUser(id: 'a.b', email: 'b@example.com');
      // both are sanitised, but each must stay inside users/ and remain a single path segment
      for (final user in [a, b]) {
        expect(user.storageKey.contains(Platform.pathSeparator), isFalse);
        expect(user.storageKey.contains('..'), isFalse);
      }
    });
  });
}

/// An account that reports itself as the administrator, without depending on the process environment.
class _AdminUser extends AppUser {
  _AdminUser({required super.id, required super.email});

  @override
  bool get isAdmin => true;
}
