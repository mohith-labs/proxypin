import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_manager.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_rule.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:proxypin/web/web_environment.dart';

/// Reverse-proxy routes of the ProxyPin web server: `<origin><path>` is forwarded to the rule's target.
class ReverseProxyPage extends StatefulWidget {
  final String? windowId;

  const ReverseProxyPage({super.key, this.windowId});

  @override
  State<ReverseProxyPage> createState() => _ReverseProxyPageState();
}

class _ReverseProxyPageState extends State<ReverseProxyPage> {
  ReverseProxyManager? manager;

  /// The signed-in user's common prefix (web only); new paths are created under it.
  String pathPrefix = WebEnvironment.pathPrefix;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  /// Base URL clients use for this server (the page is served from it).
  static String get origin => Platforms.isWeb ? Uri.base.origin : 'http://localhost:8080';

  @override
  void initState() {
    super.initState();
    ReverseProxyManager.instance.then((value) {
      if (mounted) setState(() => manager = value);
    });
  }

  /// Persists the rules; on rejection (e.g. a path another user already owns) the server's reason is shown and
  /// the on-disk state is reloaded so the list never drifts from what was actually saved.
  Future<void> _save() async {
    try {
      await manager!.flushConfig();
    } catch (e) {
      if (mounted) FlutterToastr.show(_reason(e), context, duration: 4);
      await manager!.reload();
    }
    if (mounted) setState(() {});
  }

  /// The server's message without the transport noise around it.
  static String _reason(Object error) {
    final text = error.toString();
    final match = RegExp(r'HTTP \d+ (.+)\$', dotAll: true).firstMatch(text);
    final body = match?.group(1)?.trim() ?? text;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] != null) return decoded['error'].toString();
    } catch (_) {}
    return body;
  }

  @override
  Widget build(BuildContext context) {
    final manager = this.manager;
    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.reverseProxy, style: const TextStyle(fontSize: 16)),
        toolbarHeight: 42,
        centerTitle: false,
        actions: [
          if (manager != null) ...[
            Text(localizations.reverseProxyEnable, style: const TextStyle(fontSize: 13)),
            Transform.scale(
                scale: 0.75,
                child: Switch(
                    value: manager.enabled,
                    onChanged: (value) {
                      manager.enabled = value;
                      _save();
                    })),
            const SizedBox(width: 6),
            FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add, size: 18),
                label: Text(localizations.add)),
          ],
          const SizedBox(width: 12),
        ],
      ),
      body: manager == null
          ? const Center(child: CircularProgressIndicator())
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Text(localizations.reverseProxyHint(origin),
                    style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
              ),
              const Divider(height: 1),
              Expanded(
                child: manager.rules.isEmpty
                    ? Center(
                        child: Text(localizations.reverseProxyEmpty,
                            style: TextStyle(color: Theme.of(context).hintColor)))
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: manager.rules.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
                        itemBuilder: (context, index) => _row(manager.rules[index], index),
                      ),
              ),
            ]),
    );
  }

  Widget _row(ReverseProxyRule rule, int index) {
    final theme = Theme.of(context);
    final proxyUrl = '$origin${rule.path == '/' ? '/' : rule.path}';
    final flags = [
      if (rule.stripPrefix) localizations.reverseProxyStripPrefix,
      if (rule.preserveHost) localizations.reverseProxyPreserveHost,
      if (rule.rewriteResponse) localizations.reverseProxyRewriteResponse,
    ];
    return ListTile(
      dense: true,
      leading: Transform.scale(
          scale: 0.75,
          child: Switch(
              value: rule.enabled,
              onChanged: (value) {
                rule.enabled = value;
                _save();
              })),
      title: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
        if (rule.name.isNotEmpty) Text(rule.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(rule.path, style: TextStyle(fontFamily: 'monospace', color: theme.colorScheme.primary)),
        const Icon(Icons.arrow_forward, size: 14),
        Text(rule.target, style: const TextStyle(fontFamily: 'monospace')),
      ]),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: proxyUrl));
              FlutterToastr.show(localizations.copied, context);
            },
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${localizations.reverseProxyUrl}: $proxyUrl', style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              const Icon(Icons.copy, size: 12),
            ]),
          ),
          for (final flag in flags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
              child: Text(flag, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSecondaryContainer)),
            ),
        ]),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
            tooltip: localizations.edit,
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () => _edit(index: index)),
        IconButton(
            tooltip: localizations.delete,
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => showConfirmDialog(context, onConfirm: () {
                  manager!.rules.removeAt(index);
                  _save();
                })),
      ]),
    );
  }

  Future<void> _edit({int? index}) async {
    final manager = this.manager!;
    final existing = index == null ? null : manager.rules[index];
    final result = await showDialog<ReverseProxyRule>(
        context: context,
        builder: (_) => _RuleDialog(
            rule: existing?.copy(),
            pathPrefix: pathPrefix,
            otherPaths: [
              for (final (i, rule) in manager.rules.indexed)
                if (i != index) rule.path
            ]));
    if (result == null) return;
    if (index == null) {
      manager.rules.add(result);
    } else {
      manager.rules[index] = result;
    }
    await _save();
  }
}

/// Joins a user's common prefix with the path they typed (`/user1` + `/path` -> `/user1/path`).
String _withPrefix(String prefix, String path) {
  if (prefix.isEmpty) return path;
  if (path == '/') return prefix;
  return '$prefix$path';
}

class _RuleDialog extends StatefulWidget {
  final ReverseProxyRule? rule;
  final List<String> otherPaths;

  /// The signed-in user's common prefix; new paths are created under it (shown as a prefix in the field).
  final String pathPrefix;

  const _RuleDialog({this.rule, required this.otherPaths, this.pathPrefix = ''});

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  final formKey = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.rule?.name ?? '');
  late final path = TextEditingController(text: widget.rule?.path ?? '/');
  late final target = TextEditingController(text: widget.rule?.target ?? 'https://');
  late bool stripPrefix = widget.rule?.stripPrefix ?? true;
  late bool preserveHost = widget.rule?.preserveHost ?? false;
  late bool rewriteResponse = widget.rule?.rewriteResponse ?? true;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    for (final controller in [path, target]) {
      controller.addListener(() => setState(() {}));
    }
  }

  ReverseProxyRule _build() => ReverseProxyRule(
        enabled: widget.rule?.enabled ?? true,
        name: name.text.trim(),
        path: path.text,
        target: target.text.trim(),
        stripPrefix: stripPrefix,
        preserveHost: preserveHost,
        rewriteResponse: rewriteResponse,
      );

  String? _example() {
    if (ReverseProxyRule.validateTarget(target.text.trim()) != null) return null;
    final rule = _build();
    final sample = rule.path == '/' ? '/users?id=1' : '${rule.path}/users?id=1';
    return '$sample  →  ${rule.targetUri.origin}${rule.upstreamUri(sample)}';
  }

  @override
  Widget build(BuildContext context) {
    final example = _example();
    return AlertDialog(
      title: Text(localizations.reverseProxy, style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 520,
        child: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextFormField(
                controller: name,
                decoration: InputDecoration(labelText: localizations.name, isDense: true)),
            const SizedBox(height: 10),
            TextFormField(
              controller: path,
              decoration: InputDecoration(
                  labelText: localizations.reverseProxyPath,
                  hintText: '/api',
                  isDense: true,
                  // a prefixed user types the path relative to their own prefix
                  prefixText: widget.rule == null && widget.pathPrefix.isNotEmpty ? widget.pathPrefix : null),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (!text.startsWith('/')) return localizations.reverseProxyInvalidPath;
                final normalized = ReverseProxyRule.normalizePath(text);
                if (normalized == '/__proxypin' || normalized.startsWith('/__proxypin/')) {
                  return localizations.reverseProxyReservedPath;
                }
                final full = widget.pathPrefix.isEmpty || widget.rule != null
                    ? normalized
                    : _withPrefix(widget.pathPrefix, normalized);
                // the server has the final say (it also sees other users' routes), this is just quick feedback
                for (final other in widget.otherPaths) {
                  if (ReverseProxyManager.pathsOverlap(full, other)) return localizations.reverseProxyDuplicatePath;
                }
                return null;
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: target,
              decoration: InputDecoration(
                  labelText: localizations.reverseProxyTarget, hintText: 'https://example.com', isDense: true),
              validator: (value) =>
                  ReverseProxyRule.validateTarget(value ?? '') == null ? null : localizations.reverseProxyInvalidTarget,
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: stripPrefix,
                title: Text(localizations.reverseProxyStripPrefix),
                onChanged: (value) => setState(() => stripPrefix = value ?? true)),
            CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: preserveHost,
                title: Text(localizations.reverseProxyPreserveHost),
                onChanged: (value) => setState(() => preserveHost = value ?? false)),
            CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: rewriteResponse,
                title: Text(localizations.reverseProxyRewriteResponse),
                onChanged: (value) => setState(() => rewriteResponse = value ?? true)),
            if (example != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText('${localizations.reverseProxyExample}: $example',
                    style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: Theme.of(context).hintColor)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(localizations.cancel)),
        FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(context, _build());
            },
            child: Text(localizations.save)),
      ],
    );
  }
}

/// Opens the rules page (an in-page window in the web UI).
void openReverseProxyWindow(BuildContext context) {
  MultiWindow.openWindow(AppLocalizations.of(context)!.reverseProxy, 'ReverseProxyPage', size: const Size(860, 640));
}
