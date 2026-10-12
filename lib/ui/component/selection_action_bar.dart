import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/liquid/liquid.dart';
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/utils/listenable_list.dart';

class SelectionActionBar extends StatelessWidget {
  final MultiSelectController selectionController;
  final VoidCallback? onRepeat;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;

  const SelectionActionBar({super.key, required this.selectionController, this.onRepeat, this.onExport, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);

    return GlassSurface(
        weight: GlassWeight.thick,
        borderRadius: BorderRadius.circular(GlassRadius.sm),
        margin: const EdgeInsets.fromLTRB(10, 4, 10, 2),
        height: 42,
        elevation: 0.8,
        child: Row(children: [
          const SizedBox(width: 8),
          _SelectLabel(selectionController: selectionController),
          const Spacer(),
          if (onRepeat != null) _action(Icons.repeat, localizations?.repeat, onRepeat),
          if (onExport != null) _action(Icons.share_outlined, localizations?.export, onExport),
          if (onDelete != null)
            _action(Icons.delete_outline, localizations?.delete, onDelete, color: const Color(0xFFE5484D)),
          _action(Icons.close, localizations?.cancel, _onCancel),
          const SizedBox(width: 4),
        ]));
  }

  Widget _action(IconData icon, String? tooltip, VoidCallback? onTap, {Color? color}) {
    return PressableGlass(
      onTap: onTap,
      pressedScale: 0.85,
      borderRadius: BorderRadius.circular(GlassRadius.capsule),
      child: Tooltip(
        message: tooltip ?? '',
        child: Padding(padding: const EdgeInsets.all(9), child: Icon(icon, size: 19, color: color)),
      ),
    );
  }

  void _onCancel() {
    selectionController.clear();
  }
}

class _SelectLabel extends StatefulWidget {
  final MultiSelectController selectionController;

  const _SelectLabel({required this.selectionController});

  @override
  State<StatefulWidget> createState() => _SelectLabelState();
}

class _SelectLabelState extends State<_SelectLabel> {
  late final OnchangeListEvent<String> _listener;

  @override
  void initState() {
    super.initState();
    _listener = OnchangeListEvent(_onSelectionChanged);
    widget.selectionController.selectedIds.addListener(_listener);
  }

  @override
  void dispose() {
    widget.selectionController.selectedIds.removeListener(_listener);
    super.dispose();
  }

  void _onSelectionChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final selectLabel = AppLocalizations.of(context)?.selectAction;
    final selectedCount = widget.selectionController.selectedIds.length;
    final label = (selectLabel == null || selectLabel.isEmpty) ? '$selectedCount' : '$selectedCount $selectLabel';

    return Text(label, style: Theme.of(context).textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}

class ClearSelectionIntent extends Intent {
  const ClearSelectionIntent();
}
