import 'dart:convert';

import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_manager.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_rule.dart';
import 'package:proxypin/server/auth/auth_store.dart';

/// Rejected rule edit; [message] is shown to the user.
class RuleRejected implements Exception {
  final String message;

  const RuleRejected(this.message);

  @override
  String toString() => message;
}

/// Server-side ownership rules for `reverse_proxy.json`.
///
/// The console edits routes by writing the whole file, so the browser's copy only ever contains the rules that
/// user may see. Writing it verbatim would delete everyone else's routes, so every write is merged here against
/// the rules currently on disk:
///
///  * rules the user cannot see are preserved untouched,
///  * rules they submit are stamped with their id and their path prefix,
///  * they may not take over, edit or delete somebody else's rule,
///  * no two rules may claim overlapping paths.
///
/// This is the only place that decides who owns what; the UI merely reflects it.
class ReverseProxyGuard {
  /// The rules [user] is allowed to see, as the JSON the console expects.
  static Map<String, dynamic> visibleConfig(ReverseProxyManager manager, AppUser user) => {
        'enabled': manager.enabled,
        'rules': manager
            .visibleTo(userId: user.id, isAdmin: user.isAdmin)
            .map((rule) => rule.toJson())
            .toList(growable: false),
      };

  /// Merges the user's submitted config with the rules they cannot see.
  ///
  /// [current] is the config on disk. Throws [RuleRejected] when the edit is not allowed.
  static Map<String, dynamic> merge({
    required Map<String, dynamic> current,
    required Map<String, dynamic> submitted,
    required AppUser user,
  }) {
    final existing = _rulesOf(current);
    final incoming = _rulesOf(submitted);
    final isAdmin = user.isAdmin;

    final byPath = {for (final rule in existing) rule.path: rule};
    // rules the user cannot see survive the write untouched
    final hidden = existing.where((rule) => !ReverseProxyManager.canAccess(rule, userId: user.id, isAdmin: isAdmin));
    final merged = <ReverseProxyRule>[...hidden];

    for (final rule in incoming) {
      if (!isAdmin) {
        // The prefix is resolved BEFORE looking the rule up: a prefixed user types "/test" meaning
        // "/user2/test", so comparing the bare path would collide with somebody else's "/test".
        // An edited rule arrives with its full path already under the prefix and is left alone.
        if (!_withinPrefix(rule.path, user.pathPrefix)) rule.path = user.applyPrefix(rule.path);

        final previous = byPath[rule.path];
        // A user may only keep an owner stamp they are entitled to.
        if (rule.ownerId.isNotEmpty && rule.ownerId != user.id) {
          throw RuleRejected('"${rule.path}" belongs to another user');
        }
        if (previous != null && !ReverseProxyManager.canAccess(previous, userId: user.id, isAdmin: false)) {
          throw RuleRejected('"${rule.path}" is already in use');
        }
        rule.ownerId = user.id;
      } else {
        final previous = byPath[rule.path];
        if (rule.ownerId.isEmpty && previous != null) {
          rule.ownerId = previous.ownerId; // admin editing somebody's rule keeps its owner
        }
      }

      merged.add(rule);
    }

    _rejectConflicts(merged);
    return {
      'enabled': submitted['enabled'] != false,
      'rules': merged.map((rule) => rule.toJson()).toList(growable: false),
    };
  }

  /// Moves [user]'s rules from their old prefix to [prefix]; returns the rewritten config.
  ///
  /// Their paths keep working relative to the prefix, so only the public URL changes. Throws [RuleRejected]
  /// when a moved path would collide with an existing one.
  static Map<String, dynamic> reprefix({
    required Map<String, dynamic> current,
    required AppUser user,
    required String prefix,
  }) {
    final from = user.pathPrefix;
    final to = AppUser.normalizePrefix(prefix);
    final rules = _rulesOf(current);
    if (from == to) return {'enabled': current['enabled'] != false, 'rules': rules.map((e) => e.toJson()).toList()};

    for (final rule in rules) {
      if (rule.ownerId != user.id) continue;
      final relative = _strip(rule.path, from);
      rule.path = to.isEmpty ? (relative.isEmpty ? '/' : relative) : '$to$relative';
    }

    _rejectConflicts(rules);
    return {
      'enabled': current['enabled'] != false,
      'rules': rules.map((rule) => rule.toJson()).toList(growable: false),
    };
  }

  /// The part of [path] after [prefix] (`/u1/a` under `/u1` -> `/a`).
  static String _strip(String path, String prefix) {
    if (prefix.isEmpty) return path == '/' ? '' : path;
    if (path == prefix) return '';
    if (path.startsWith('$prefix/')) return path.substring(prefix.length);
    return path == '/' ? '' : path; // never had the prefix
  }

  static bool _withinPrefix(String path, String prefix) {
    if (prefix.isEmpty) return true;
    return path == prefix || path.startsWith('$prefix/');
  }

  /// Throws when two rules would capture overlapping traffic.
  static void _rejectConflicts(List<ReverseProxyRule> rules) {
    for (var i = 0; i < rules.length; i++) {
      for (var j = i + 1; j < rules.length; j++) {
        final a = rules[i];
        final b = rules[j];
        if (!ReverseProxyManager.pathsOverlap(a.path, b.path)) continue;
        final detail = a.path == b.path ? '"${a.path}" is already in use' : '"${a.path}" overlaps "${b.path}"';
        throw RuleRejected(detail);
      }
    }
  }

  static List<ReverseProxyRule> _rulesOf(Map<String, dynamic> config) => ((config['rules'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => ReverseProxyRule.fromJson(Map<String, dynamic>.from(e)))
      .toList();

  static Map<String, dynamic> decode(List<int> bytes) {
    if (bytes.isEmpty) return {'rules': []};
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const RuleRejected('reverse proxy config must be an object');
    return Map<String, dynamic>.from(decoded);
  }

  static List<int> encode(Map<String, dynamic> config) =>
      utf8.encode(const JsonEncoder.withIndent('  ').convert(config));
}
