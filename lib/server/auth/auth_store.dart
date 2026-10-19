import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/server/server_environment.dart';

/// Lifecycle of an account. A user that signs in while signup is closed is kept as [pending]
/// (the admin's "requests" list) and cannot use the console until approved.
enum UserStatus { pending, approved, blocked }

UserStatus userStatusFrom(String? value) => switch (value) {
      'approved' => UserStatus.approved,
      'blocked' => UserStatus.blocked,
      _ => UserStatus.pending,
    };

/// How [AuthSettings.domains] is applied to the email domain of a user signing in for the first time.
enum DomainMode { off, allow, block }

DomainMode domainModeFrom(String? value) => switch (value) {
      'allow' => DomainMode.allow,
      'block' => DomainMode.block,
      _ => DomainMode.off,
    };

class AppUser {
  final String id; // Google "sub": stable per account, unlike the email
  String email;
  String name;
  String picture;
  UserStatus status;
  final DateTime createdAt;
  DateTime? lastLoginAt;

  AppUser({
    required this.id,
    required this.email,
    this.name = '',
    this.picture = '',
    this.status = UserStatus.pending,
    DateTime? createdAt,
    this.lastLoginAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// The admin is defined by PROXYPIN_ADMIN_EMAIL, never by stored state, so it cannot be revoked from the UI.
  bool get isAdmin => ServerEnvironment.isAdminEmail(email);

  /// Directory name for this user's data; derived from the Google subject, never from the email.
  String get storageKey => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  String get domain {
    final at = email.lastIndexOf('@');
    return at < 0 ? '' : email.substring(at + 1).toLowerCase();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'name': name,
        'picture': picture,
        'status': status.name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        if (lastLoginAt != null) 'lastLoginAt': lastLoginAt!.millisecondsSinceEpoch,
      };

  static AppUser fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        picture: json['picture']?.toString() ?? '',
        status: userStatusFrom(json['status']?.toString()),
        createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int? ?? 0),
        lastLoginAt:
            json['lastLoginAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['lastLoginAt'] as int),
      );

  /// What the UI is allowed to see (same shape for the session and the admin list).
  Map<String, dynamic> toPublicJson() => {
        'id': id,
        'email': email,
        'name': name,
        'picture': picture,
        'status': status.name,
        'isAdmin': isAdmin,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastLoginAt': lastLoginAt?.millisecondsSinceEpoch,
      };
}

/// Admin-controlled rules applied when somebody signs in for the first time.
class AuthSettings {
  /// Off: a new Google account lands in the request list instead of getting access.
  bool allowSignup;
  DomainMode domainMode;
  List<String> domains;

  AuthSettings({this.allowSignup = true, this.domainMode = DomainMode.off, List<String>? domains})
      : domains = domains ?? [];

  Map<String, dynamic> toJson() => {
        'allowSignup': allowSignup,
        'domainMode': domainMode.name,
        'domains': domains,
      };

  static AuthSettings fromJson(Map<String, dynamic> json) => AuthSettings(
        allowSignup: json['allowSignup'] != false,
        domainMode: domainModeFrom(json['domainMode']?.toString()),
        domains: ((json['domains'] as List?) ?? const []).map((e) => normalizeDomain(e.toString())).where((e) => e.isNotEmpty).toList(),
      );

  /// Accepts `@tricog.com`, `tricog.com` or `TRICOG.COM` and stores one canonical form.
  static String normalizeDomain(String value) {
    var domain = value.trim().toLowerCase();
    if (domain.startsWith('@')) domain = domain.substring(1);
    return domain;
  }

  /// A rule matches the domain itself and its subdomains (`tricog.com` also matches `mail.tricog.com`).
  bool _listed(String domain) =>
      domains.any((rule) => rule.isNotEmpty && (domain == rule || domain.endsWith('.$rule')));

  bool allowsDomain(String domain) => switch (domainMode) {
        DomainMode.off => true,
        DomainMode.allow => _listed(domain),
        DomainMode.block => !_listed(domain),
      };
}

/// Users and auth settings, persisted as one JSON file in the data directory.
class AuthStore {
  static const String fileName = 'auth.json';

  final File _file;
  final Map<String, AppUser> _users = {};
  AuthSettings settings = AuthSettings();
  Future<void> _writing = Future.value();

  AuthStore._(this._file);

  static AuthStore? _instance;

  static Future<AuthStore> get instance async {
    if (_instance != null) return _instance!;
    final file = File('${ServerEnvironment.dataDir}${Platform.pathSeparator}$fileName');
    final store = AuthStore._(file);
    await store._load();
    return _instance = store;
  }

  /// Drops the cached store (tests).
  static void reset() => _instance = null;

  Future<void> _load() async {
    if (!await _file.exists()) return;
    try {
      final content = await _file.readAsString();
      if (content.trim().isEmpty) return;
      final json = jsonDecode(content) as Map<String, dynamic>;
      settings = AuthSettings.fromJson(Map<String, dynamic>.from(json['settings'] as Map? ?? const {}));
      for (final entry in (json['users'] as List? ?? const [])) {
        final user = AppUser.fromJson(Map<String, dynamic>.from(entry as Map));
        if (user.id.isNotEmpty) _users[user.id] = user;
      }
    } catch (e, t) {
      logger.e('auth.json is unreadable; starting with an empty user list', error: e, stackTrace: t);
    }
  }

  /// Serialized so concurrent logins cannot interleave writes to the same file.
  Future<void> save() {
    return _writing = _writing.then((_) async {
      final json = jsonEncode({
        'settings': settings.toJson(),
        'users': _users.values.map((e) => e.toJson()).toList(),
      });
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString(json, flush: true);
      await temp.rename(_file.path);
    }).catchError((Object e, StackTrace t) {
      logger.e('cannot persist auth.json', error: e, stackTrace: t);
    });
  }

  List<AppUser> get users {
    final list = _users.values.toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  AppUser? byId(String? id) => id == null ? null : _users[id];

  AppUser? byEmail(String email) {
    final needle = email.toLowerCase();
    for (final user in _users.values) {
      if (user.email.toLowerCase() == needle) return user;
    }
    return null;
  }

  int get pendingCount => _users.values.where((u) => u.status == UserStatus.pending).length;

  Future<void> setStatus(AppUser user, UserStatus status) async {
    user.status = status;
    await save();
  }

  Future<void> remove(String id) async {
    _users.remove(id);
    await save();
  }

  Future<void> updateSettings(AuthSettings updated) async {
    settings = updated;
    await save();
  }

  /// Resolves the Google profile to an account and decides whether it may sign in.
  ///
  /// The admin email is always admitted and repaired to [UserStatus.approved], so a misconfigured
  /// signup rule can never lock the owner out of the console.
  Future<SignInResult> signIn({
    required String subject,
    required String email,
    required String name,
    required String picture,
  }) async {
    final isAdmin = ServerEnvironment.isAdminEmail(email);
    var user = _users[subject] ?? byEmail(email);

    if (user == null) {
      final domain = email.contains('@') ? email.split('@').last.toLowerCase() : '';
      if (!isAdmin && !settings.allowsDomain(domain)) {
        return SignInResult.rejected('Sign-in is not allowed for the domain @$domain.');
      }
      user = AppUser(
        id: subject,
        email: email,
        name: name,
        picture: picture,
        status: (isAdmin || settings.allowSignup) ? UserStatus.approved : UserStatus.pending,
      );
      _users[subject] = user;
    } else {
      // keep the profile fresh, and migrate a record that was created before we knew the subject
      if (user.id != subject) {
        _users.remove(user.id);
        user = AppUser(
          id: subject,
          email: email,
          name: name,
          picture: picture,
          status: user.status,
          createdAt: user.createdAt,
          lastLoginAt: user.lastLoginAt,
        );
        _users[subject] = user;
      }
      user.email = email;
      if (name.isNotEmpty) user.name = name;
      if (picture.isNotEmpty) user.picture = picture;
    }

    if (isAdmin && user.status != UserStatus.approved) user.status = UserStatus.approved;

    if (user.status == UserStatus.blocked) {
      await save();
      return SignInResult.rejected('This account has been blocked by the administrator.');
    }

    if (user.status == UserStatus.approved) user.lastLoginAt = DateTime.now();
    await save();
    return SignInResult.ok(user);
  }
}

class SignInResult {
  final AppUser? user;
  final String? error;

  SignInResult.ok(this.user) : error = null;

  SignInResult.rejected(this.error) : user = null;

  bool get allowed => user != null;

  /// Signed in, but still waiting for the admin to approve the account.
  bool get pending => user?.status == UserStatus.pending;
}
