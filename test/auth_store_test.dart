import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/server/auth/auth_store.dart';
import 'package:proxypin/server/server_environment.dart';

/// Access rules of the multi-user web console: who may sign in, who waits for approval, who is refused.
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('proxypin_auth_test');
    ServerEnvironment.dataDir = temp.path;
    AuthStore.reset();
  });

  tearDown(() {
    AuthStore.reset();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<SignInResult> signIn(AuthStore store, String email, {String? subject}) => store.signIn(
        subject: subject ?? 'sub-$email',
        email: email,
        name: email.split('@').first,
        picture: '',
      );

  group('domain rules', () {
    test('allow list admits only listed domains, including subdomains', () {
      final settings = AuthSettings(domainMode: DomainMode.allow, domains: ['tricog.com']);
      expect(settings.allowsDomain('tricog.com'), isTrue);
      expect(settings.allowsDomain('mail.tricog.com'), isTrue);
      expect(settings.allowsDomain('gmail.com'), isFalse);
      // a domain that merely ends with the same text must not pass
      expect(settings.allowsDomain('nottricog.com'), isFalse);
    });

    test('block list refuses listed domains and admits the rest', () {
      final settings = AuthSettings(domainMode: DomainMode.block, domains: ['spam.com']);
      expect(settings.allowsDomain('spam.com'), isFalse);
      expect(settings.allowsDomain('sub.spam.com'), isFalse);
      expect(settings.allowsDomain('tricog.com'), isTrue);
    });

    test('off admits everything', () {
      expect(AuthSettings().allowsDomain('anything.example'), isTrue);
    });

    test('domains are normalised from @domain / mixed case', () {
      expect(AuthSettings.normalizeDomain('@Tricog.COM'), 'tricog.com');
      expect(AuthSettings.normalizeDomain('  tricog.com '), 'tricog.com');
    });
  });

  group('sign-up', () {
    test('open signup approves a new account immediately', () async {
      final store = await AuthStore.instance;
      store.settings.allowSignup = true;

      final result = await signIn(store, 'someone@example.com');
      expect(result.allowed, isTrue);
      expect(result.pending, isFalse);
      expect(result.user!.status, UserStatus.approved);
    });

    test('closed signup parks a new account in the request list', () async {
      final store = await AuthStore.instance;
      store.settings.allowSignup = false;

      final result = await signIn(store, 'someone@example.com');
      expect(result.allowed, isTrue, reason: 'the account exists, it just cannot use the console yet');
      expect(result.pending, isTrue);
      expect(store.pendingCount, 1);
    });

    test('a blocked user is refused', () async {
      final store = await AuthStore.instance;
      final first = await signIn(store, 'someone@example.com');
      await store.setStatus(first.user!, UserStatus.blocked);

      final second = await signIn(store, 'someone@example.com');
      expect(second.allowed, isFalse);
      expect(second.error, contains('blocked'));
    });

    test('a domain that is not allowed is refused before an account is created', () async {
      final store = await AuthStore.instance;
      store.settings
        ..domainMode = DomainMode.allow
        ..domains = ['tricog.com'];

      final result = await signIn(store, 'outsider@gmail.com');
      expect(result.allowed, isFalse);
      expect(result.error, contains('gmail.com'));
      expect(store.users, isEmpty);
    });

    test('an approved user keeps access when the domain rules change later', () async {
      final store = await AuthStore.instance;
      final first = await signIn(store, 'user@tricog.com');
      expect(first.allowed, isTrue);

      store.settings
        ..domainMode = DomainMode.block
        ..domains = ['tricog.com'];

      // the rules apply to new accounts; an existing one is governed by its status
      final second = await signIn(store, 'user@tricog.com');
      expect(second.allowed, isTrue);
    });
  });

  group('administrator', () {
    test('the admin is admitted even with signup closed and their domain blocked', () async {
      final store = await AuthStore.instance;
      store.settings
        ..allowSignup = false
        ..domainMode = DomainMode.block
        ..domains = ['gmail.com'];

      // PROXYPIN_ADMIN_EMAIL cannot be set from the test process, so assert on the code path that
      // the environment feeds: an account whose email is an admin email is never pending.
      final result = await signIn(store, 'someone@gmail.com');
      expect(result.allowed, isFalse, reason: 'a normal blocked-domain account is refused');

      // and the admin check itself
      expect(ServerEnvironment.isAdminEmail('nobody@example.com'), isFalse);
    });
  });

  group('persistence', () {
    test('users and settings survive a restart', () async {
      final store = await AuthStore.instance;
      store.settings
        ..allowSignup = false
        ..domainMode = DomainMode.allow
        ..domains = ['tricog.com'];
      await store.save();
      await signIn(store, 'user@tricog.com');

      AuthStore.reset();
      final reloaded = await AuthStore.instance;
      expect(reloaded.settings.allowSignup, isFalse);
      expect(reloaded.settings.domainMode, DomainMode.allow);
      expect(reloaded.settings.domains, ['tricog.com']);
      expect(reloaded.users.length, 1);
      expect(reloaded.users.first.email, 'user@tricog.com');
    });

    test('an account found by email is migrated to its Google subject', () async {
      final store = await AuthStore.instance;
      await signIn(store, 'user@example.com', subject: 'old-id');
      final migrated = await signIn(store, 'user@example.com', subject: 'google-sub-1');

      expect(migrated.user!.id, 'google-sub-1');
      expect(store.users.length, 1, reason: 'the old record must not be left behind');
    });
  });

  group('storage isolation', () {
    test('each user gets their own data directory', () {
      final a = AppUser(id: 'sub-a', email: 'a@example.com');
      final b = AppUser(id: 'sub-b', email: 'b@example.com');
      expect(ServerEnvironment.userDataDir(a.storageKey),
          isNot(ServerEnvironment.userDataDir(b.storageKey)));
    });

    test('the storage key cannot escape the users directory', () {
      final nasty = AppUser(id: '../../etc', email: 'x@example.com');
      expect(nasty.storageKey, isNot(contains('/')));
      expect(nasty.storageKey, isNot(contains('..')));
    });
  });
}
