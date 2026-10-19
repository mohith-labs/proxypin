import 'dart:convert';

import 'package:meta/meta.dart';

import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/storage/path.dart';
import 'package:proxypin/utils/io.dart';

import 'reverse_proxy_rule.dart';

/// Reverse-proxy routes (`reverse_proxy.json` in the app data directory).
///
/// The headless server routes every request that is not for the UI through [match]; the web UI edits the rules
/// through the same file (the server reloads it when it changes).
class ReverseProxyManager {
  static const String fileName = 'reverse_proxy.json';

  static ReverseProxyManager? _instance;

  static Future<ReverseProxyManager> get instance async {
    if (_instance == null) {
      final manager = ReverseProxyManager._();
      await manager.reload();
      _instance = manager;
    }
    return _instance!;
  }

  /// Synchronous access once loaded (request hot path).
  static ReverseProxyManager? get instanceOrNull => _instance;

  ReverseProxyManager._();

  /// A detached manager with a fixed rule set, for tests.
  @visibleForTesting
  factory ReverseProxyManager.forTest(List<ReverseProxyRule> rules) => ReverseProxyManager._()..rules.addAll(rules);

  bool enabled = true;
  final List<ReverseProxyRule> rules = [];

  static Future<File> _file() async => File('${await Paths.homePath()}${Platform.pathSeparator}$fileName');

  Future<void> reload() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        rules.clear();
        return;
      }
      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        rules.clear();
        return;
      }
      final config = jsonDecode(content) as Map<String, dynamic>;
      enabled = config['enabled'] != false;
      rules
        ..clear()
        ..addAll(((config['rules'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ReverseProxyRule.fromJson(Map<String, dynamic>.from(e))));
    } catch (e, t) {
      logger.e('load $fileName failed', error: e, stackTrace: t);
    }
  }

  Map<String, dynamic> toJson() => {'enabled': enabled, 'rules': rules.map((e) => e.toJson()).toList()};

  Future<void> flushConfig() async {
    final file = await _file();
    await file.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  /// The enabled rule with the longest matching prefix; the first one wins a tie.
  ReverseProxyRule? match(String path) {
    if (!enabled) return null;
    ReverseProxyRule? best;
    for (final rule in rules) {
      if (!rule.enabled || !rule.matches(path)) continue;
      if (best == null || rule.path.length > best.path.length) best = rule;
    }
    return best;
  }

  /// Whether [userId] may see and edit [rule]. Admins see everything; everyone else sees only their own.
  /// Rules written before ownership existed have no owner and belong to the admin.
  static bool canAccess(ReverseProxyRule rule, {required String userId, required bool isAdmin}) {
    if (isAdmin) return true;
    return rule.ownerId.isNotEmpty && rule.ownerId == userId;
  }

  /// The rules [userId] may see.
  List<ReverseProxyRule> visibleTo({required String userId, required bool isAdmin}) =>
      rules.where((rule) => canAccess(rule, userId: userId, isAdmin: isAdmin)).toList();

  /// Returns the rule that would collide with [path], or null when the path is free.
  ///
  /// Two rules collide when one would swallow the other's traffic: identical paths, or one being a path-segment
  /// prefix of the other (`/a` vs `/a/b`), since the longest-prefix [match] would make the inner one unreachable
  /// for part of its range. [ignore] is the rule being edited, so renaming a rule to its own path is allowed.
  ReverseProxyRule? findConflict(String path, {ReverseProxyRule? ignore}) {
    final candidate = ReverseProxyRule.normalizePath(path);
    for (final rule in rules) {
      if (identical(rule, ignore)) continue;
      if (pathsOverlap(candidate, rule.path)) return rule;
    }
    return null;
  }

  /// Whether two path prefixes would capture overlapping traffic, making one unreachable for part of its range.
  static bool pathsOverlap(String a, String b) {
    if (a == b) return true;
    if (a == '/' || b == '/') return true; // `/` catches everything
    return a.startsWith('$b/') || b.startsWith('$a/');
  }
}
