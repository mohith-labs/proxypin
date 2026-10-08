import 'dart:convert';

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
}
