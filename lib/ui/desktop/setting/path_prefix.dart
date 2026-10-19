import 'package:flutter/material.dart';
import 'package:proxypin/network/components/reverse_proxy/reverse_proxy_rule.dart';
import 'package:proxypin/web/remote/api_client.dart';
import 'package:proxypin/web/web_environment.dart';

/// Lets the signed-in user pick a common prefix for every route they create.
///
/// With a prefix of `/user1`, asking for `/path` produces `/user1/path`. Changing it moves the routes they
/// already own, so their paths keep working and only the public URL changes.
Future<void> showPathPrefixDialog(BuildContext context) async {
  await showDialog<void>(context: context, builder: (_) => const _PathPrefixDialog());
}

class _PathPrefixDialog extends StatefulWidget {
  const _PathPrefixDialog();

  @override
  State<_PathPrefixDialog> createState() => _PathPrefixDialogState();
}

class _PathPrefixDialogState extends State<_PathPrefixDialog> {
  late final TextEditingController _controller = TextEditingController(text: WebEnvironment.pathPrefix);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _normalized {
    final value = _controller.text.trim();
    if (value.isEmpty) return '';
    final path = ReverseProxyRule.normalizePath(value);
    return path == '/' ? '' : path;
  }

  Future<void> _save() async {
    final prefix = _normalized;
    if (prefix == '/__proxypin' || prefix.startsWith('/__proxypin/')) {
      setState(() => _error = 'That path is reserved for the console.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ApiClient.postJson('me/prefix', json: {'prefix': prefix});
      final user = result['user'];
      if (user is Map) WebEnvironment.currentUser = Map<String, dynamic>.from(user);
      final moved = (result['moved'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(moved == 0
              ? (prefix.isEmpty ? 'Prefix removed.' : 'Prefix set to $prefix.')
              : 'Prefix set to ${prefix.isEmpty ? "none" : prefix}; moved $moved route${moved == 1 ? "" : "s"}.')));
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _reason(e);
        });
      }
    }
  }

  /// The server's message without the transport noise around it.
  static String _reason(Object error) {
    final text = error.toString();
    final match = RegExp(r'\((\d{3}),\s*(.+)\)$', dotAll: true).firstMatch(text);
    return match?.group(2)?.trim() ?? text;
  }

  @override
  Widget build(BuildContext context) {
    final prefix = _normalized;
    return AlertDialog(
      title: const Text('My path prefix', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
              'Every route you create is placed under this prefix, so your paths cannot clash with another '
              'user\'s. Leave it empty to use your paths exactly as you type them.',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_saving,
            decoration: const InputDecoration(labelText: 'Prefix', hintText: '/user1', isDense: true),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _saving ? null : _save(),
          ),
          const SizedBox(height: 10),
          Text(
              prefix.isEmpty
                  ? 'Your route "/path" stays "/path".'
                  : 'Your route "/path" becomes "$prefix/path".',
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
          if (WebEnvironment.pathPrefix != prefix) ...[
            const SizedBox(height: 8),
            Text('Routes you already own are moved to the new prefix.',
                style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}
