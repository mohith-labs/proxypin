import 'package:flutter/material.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/web/remote/api_client.dart';

/// Admin console: who may use this ProxyPin server.
///
/// Only reachable for accounts listed in PROXYPIN_ADMIN_EMAIL; the server enforces that independently
/// (`/__proxypin/api/admin/*` answers 403 otherwise), this page only hides the entry point.
class UsersPage extends StatefulWidget {
  final String? windowId;

  const UsersPage({super.key, this.windowId});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  List<Map<String, dynamic>> _users = [];
  Map<String, dynamic> _settings = {};
  List<String> _adminEmails = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await ApiClient.getJson('admin/users');
      if (!mounted) return;
      setState(() {
        _users = ((json['users'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _settings = Map<String, dynamic>.from(json['settings'] as Map? ?? const {});
        _adminEmails = ((json['adminEmails'] as List?) ?? const []).map((e) => e.toString()).toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _saveSettings(Map<String, dynamic> change) async {
    final previous = Map<String, dynamic>.from(_settings);
    setState(() => _settings = {..._settings, ...change});
    try {
      final json = await ApiClient.postJson('admin/settings', json: change);
      if (!mounted) return;
      setState(() => _settings = Map<String, dynamic>.from(json['settings'] as Map? ?? const {}));
    } catch (e) {
      if (!mounted) return;
      setState(() => _settings = previous); // put the switch back where it was
      _toast('$e');
    }
  }

  Future<void> _setStatus(Map<String, dynamic> user, String status) async {
    try {
      await ApiClient.postJson('admin/user/status', json: {'id': user['id'], 'status': status});
      await _load();
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _delete(Map<String, dynamic> user) async {
    final deleteData = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove user'),
        content: Text('Remove ${user['email']}? They can sign in again unless signup is closed '
            'or their domain is blocked.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Remove, keep their data')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Remove with data')),
        ],
      ),
    );
    if (deleteData == null) return;
    try {
      await ApiClient.postJson('admin/user/delete', json: {'id': user['id'], 'deleteData': deleteData});
      await _load();
    } catch (e) {
      _toast('$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final pending = _users.where((u) => u['status'] == 'pending').toList();
    final active = _users.where((u) => u['status'] != 'pending').toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Users', style: TextStyle(fontSize: 16)),
        toolbarHeight: 36,
        centerTitle: true,
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 20), tooltip: 'Refresh'),
          if (widget.windowId != null)
            IconButton(
                onPressed: () => WindowController.fromWindowId(widget.windowId!).close(),
                icon: const Icon(Icons.close, size: 20)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('Retry')),
                ]))
              : ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
                  _accessCard(),
                  const SizedBox(height: 16),
                  _retentionCard(),
                  const SizedBox(height: 16),
                  if (pending.isNotEmpty) ...[
                    _sectionTitle('Requests', badge: pending.length),
                    const SizedBox(height: 6),
                    Card(child: Column(children: pending.map(_pendingTile).toList())),
                    const SizedBox(height: 16),
                  ],
                  _sectionTitle('Users', badge: active.length),
                  const SizedBox(height: 6),
                  if (active.isEmpty)
                    const Card(
                        child: Padding(padding: EdgeInsets.all(16), child: Text('Nobody has signed in yet.')))
                  else
                    Card(child: Column(children: active.map(_userTile).toList())),
                ]),
    );
  }

  Widget _sectionTitle(String text, {int? badge}) => Row(children: [
        Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        if (badge != null && badge > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
            child: Text('$badge', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ],
      ]);

  // ------------------------------------------------------------------------------------- traffic retention

  /// Preset retention windows; `custom` opens a free-form hours field.
  static const Map<String, int> _retentionPresets = {
    'Keep everything': 0,
    'Every day': 24,
    'Every week': 24 * 7,
    'Every month': 24 * 30,
  };

  int get _retentionHours => (_settings['retentionHours'] as num?)?.toInt() ?? 0;

  Widget _retentionCard() {
    final hours = _retentionHours;
    final isPreset = _retentionPresets.containsValue(hours);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Traffic retention', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
              hours == 0
                  ? 'Captured traffic is kept until the server restarts or somebody clears it.'
                  : 'Captured traffic older than ${_describe(hours)} is removed automatically.',
              style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final entry in _retentionPresets.entries)
              ChoiceChip(
                label: Text(entry.key, style: const TextStyle(fontSize: 12)),
                selected: hours == entry.value,
                onSelected: (_) => _saveSettings({'retentionHours': entry.value}),
              ),
            ChoiceChip(
              label: Text(isPreset ? 'Custom' : 'Custom (${_describe(hours)})',
                  style: const TextStyle(fontSize: 12)),
              selected: !isPreset,
              onSelected: (_) => _askCustomRetention(),
            ),
          ]),
          if (hours > 0) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text('The sweep also runs now, and then hourly.',
                    style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
              ),
              TextButton.icon(
                onPressed: _sweepNow,
                icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                label: const Text('Clear old traffic now', style: TextStyle(fontSize: 12)),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  static String _describe(int hours) {
    if (hours <= 0) return 'never';
    if (hours % (24 * 30) == 0) {
      final months = hours ~/ (24 * 30);
      return months == 1 ? '1 month' : '$months months';
    }
    if (hours % (24 * 7) == 0) {
      final weeks = hours ~/ (24 * 7);
      return weeks == 1 ? '1 week' : '$weeks weeks';
    }
    if (hours % 24 == 0) {
      final days = hours ~/ 24;
      return days == 1 ? '1 day' : '$days days';
    }
    return hours == 1 ? '1 hour' : '$hours hours';
  }

  Future<void> _askCustomRetention() async {
    final controller = TextEditingController(text: _retentionHours > 0 ? '$_retentionHours' : '');
    final hours = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Custom retention', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Hours', hintText: '72', isDense: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, int.tryParse(controller.text.trim())),
              child: const Text('Save')),
        ],
      ),
    );
    if (hours == null || hours < 0) return;
    await _saveSettings({'retentionHours': hours});
  }

  Future<void> _sweepNow() async {
    try {
      final result = await ApiClient.postJson('admin/traffic/sweep', json: const {});
      final removed = (result['removed'] as num?)?.toInt() ?? 0;
      _toast(removed == 0 ? 'Nothing was old enough to remove.' : 'Removed $removed exchanges.');
    } catch (e) {
      _toast('$e');
    }
  }

  // ------------------------------------------------------------------------------------- access rules

  Widget _accessCard() {
    final allowSignup = _settings['allowSignup'] != false;
    final domainMode = _settings['domainMode']?.toString() ?? 'off';
    final domains = ((_settings['domains'] as List?) ?? const []).map((e) => e.toString()).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: allowSignup,
            onChanged: (value) => _saveSettings({'allowSignup': value}),
            title: const Text('Allow sign-up', style: TextStyle(fontSize: 14)),
            subtitle: Text(
                allowSignup
                    ? 'New Google accounts get access immediately.'
                    : 'New accounts wait in the request list until you approve them.',
                style: const TextStyle(fontSize: 12)),
          ),
          const Divider(height: 20),
          const Text('Email domains', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
              switch (domainMode) {
                'allow' => 'Only the domains below may sign in.',
                'block' => 'The domains below may not sign in.',
                _ => 'Every email domain may sign in.',
              },
              style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'off', label: Text('Off')),
              ButtonSegment(value: 'allow', label: Text('Allow list')),
              ButtonSegment(value: 'block', label: Text('Block list')),
            ],
            selected: {domainMode},
            onSelectionChanged: (value) => _saveSettings({'domainMode': value.first}),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          if (domainMode != 'off') ...[
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ...domains.map((domain) => Chip(
                    label: Text('@$domain', style: const TextStyle(fontSize: 12)),
                    onDeleted: () =>
                        _saveSettings({'domains': domains.where((e) => e != domain).toList()}),
                    visualDensity: VisualDensity.compact,
                  )),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('Add domain', style: TextStyle(fontSize: 12)),
                onPressed: () => _addDomain(domains),
                visualDensity: VisualDensity.compact,
              ),
            ]),
            if (domains.isEmpty && domainMode == 'allow')
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('With an empty allow list nobody new can sign in.',
                    style: TextStyle(fontSize: 12, color: Colors.orange)),
              ),
          ],
          if (_adminEmails.isNotEmpty) ...[
            const Divider(height: 24),
            Text('Administrator: ${_adminEmails.join(', ')}', style: const TextStyle(fontSize: 12)),
            const Text('Set with PROXYPIN_ADMIN_EMAIL; always allowed to sign in.',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ]),
      ),
    );
  }

  Future<void> _addDomain(List<String> domains) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add domain'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'tricog.com', prefixText: '@', border: OutlineInputBorder()),
          onSubmitted: (text) => Navigator.pop(context, text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Add')),
        ],
      ),
    );

    var domain = value?.trim().toLowerCase() ?? '';
    if (domain.startsWith('@')) domain = domain.substring(1);
    if (domain.isEmpty || domains.contains(domain)) return;
    await _saveSettings({'domains': [...domains, domain]});
  }

  // ------------------------------------------------------------------------------------------- users

  Widget _pendingTile(Map<String, dynamic> user) => ListTile(
        leading: _avatar(user),
        title: Text(user['name']?.toString().isNotEmpty == true ? user['name'].toString() : user['email'].toString(),
            style: const TextStyle(fontSize: 14)),
        subtitle: Text(user['email'].toString(), style: const TextStyle(fontSize: 12)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          TextButton(onPressed: () => _setStatus(user, 'approved'), child: const Text('Approve')),
          TextButton(
            onPressed: () => _setStatus(user, 'blocked'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Deny'),
          ),
        ]),
      );

  Widget _userTile(Map<String, dynamic> user) {
    final isAdmin = user['isAdmin'] == true;
    final blocked = user['status'] == 'blocked';
    return ListTile(
      leading: _avatar(user),
      title: Row(children: [
        Flexible(
            child: Text(
                user['name']?.toString().isNotEmpty == true ? user['name'].toString() : user['email'].toString(),
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis)),
        if (isAdmin) ...[const SizedBox(width: 8), _tag('admin', Colors.blue)],
        if (blocked) ...[const SizedBox(width: 8), _tag('blocked', Colors.red)],
      ]),
      subtitle: Text(
          '${user['email']}${user['lastLoginAt'] == null ? '' : ' · last sign-in ${_date(user['lastLoginAt'])}'}',
          style: const TextStyle(fontSize: 12)),
      trailing: isAdmin
          ? null // the admin account cannot block or remove itself
          : Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(
                onPressed: () => _setStatus(user, blocked ? 'approved' : 'blocked'),
                child: Text(blocked ? 'Unblock' : 'Block'),
              ),
              IconButton(
                onPressed: () => _delete(user),
                icon: const Icon(Icons.delete_outline, size: 19),
                tooltip: 'Remove',
              ),
            ]),
    );
  }

  Widget _avatar(Map<String, dynamic> user) {
    final picture = user['picture']?.toString();
    final label = (user['name']?.toString().isNotEmpty == true
            ? user['name'].toString()
            : user['email']?.toString() ?? '?')
        .characters
        .first
        .toUpperCase();
    return CircleAvatar(
      radius: 16,
      foregroundImage: picture != null && picture.isNotEmpty ? NetworkImage(picture) : null,
      child: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }

  static Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
      );

  static String _date(dynamic millis) {
    if (millis is! int) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    final difference = DateTime.now().difference(date);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    if (difference.inDays < 30) return '${difference.inDays}d ago';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

/// Opens the user administration page (an in-page window in the web UI).
void openUsersWindow(BuildContext context) {
  MultiWindow.openWindow('Users', 'UsersPage', size: const Size(760, 680));
}
