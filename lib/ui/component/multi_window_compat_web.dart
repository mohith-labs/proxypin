/// Web version of the desktop multi-window layer.
///
/// The desktop app opens editors, settings and tools in separate OS windows (each its own engine). In the
/// browser they become floating in-page windows rendering the same widgets (`multiWindow()`), and the
/// window-to-window method calls are delivered in-process.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/utils/navigator.dart';

typedef DesktopMultiWindowMethodHandler = Future<dynamic> Function(MethodCall call, String fromWindowId);

class DesktopMultiWindow {
  /// Handles calls addressed to the main window (refresh*, resume*, registerConsoleLog...). Set by the web app.
  static DesktopMultiWindowMethodHandler? webMainHandler;

  /// Handlers registered by windows for calls coming from the main window (e.g. script console logs).
  static final List<DesktopMultiWindowMethodHandler> _windowHandlers = [];

  static String? get currentWindowId => '0';

  static Future<WindowController> ensureInitialized({String? mainWindowId}) async => WindowController.fromWindowId('0');

  static void initializeFromArguments(Map<dynamic, dynamic> arguments) {}

  static Future<WindowController> createWindow(String arguments) async => WebWindows.create(arguments);

  static Future<T?> invokeMainWindowMethod<T>(String method, [dynamic arguments]) async {
    final result = await webMainHandler?.call(MethodCall(method, arguments), '');
    return result is T ? result : null;
  }

  static Future<T?> invokeMethod<T>(Object windowId, String method, [dynamic arguments]) async {
    if (windowId.toString() == '0') return invokeMainWindowMethod<T>(method, arguments);
    dynamic result;
    for (final handler in List.of(_windowHandlers)) {
      try {
        result = await handler(MethodCall(method, arguments), '0');
      } catch (_) {
        _windowHandlers.remove(handler); // its window is gone
      }
    }
    return result is T ? result : null;
  }

  static Future<void> setMethodHandler(DesktopMultiWindowMethodHandler handler) async {
    if (!_windowHandlers.contains(handler)) _windowHandlers.add(handler);
  }
}

class WindowController {
  final String windowId;

  WindowController._(this.windowId);

  static WindowController fromWindowId(String windowId) => WindowController._(windowId);

  String get arguments => jsonEncode(WebWindows._windows[windowId]?.arguments ?? const {});

  Future<void> show() async => WebWindows.show(windowId);

  Future<void> hide() async => WebWindows.close(windowId);

  Future<void> close() async => WebWindows.close(windowId);

  Future<void> center() async {}

  Future<void> setTitle(String title) async => WebWindows._update(windowId, (w) => w.title = title);

  Future<void> setSize(Size size) async => WebWindows._update(windowId, (w) => w.size = size);

  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      DesktopMultiWindow.invokeMethod<T>(windowId, method, arguments);

  Future<void> setWindowMethodHandler(Future<dynamic> Function(MethodCall call)? handler) async {}
}

class _WebWindow {
  final String id;
  final Map<String, dynamic> arguments;
  final GlobalKey key = GlobalKey();
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey();
  String title;
  Size size = const Size(800, 680);
  Offset? position;
  bool visible = false;

  _WebWindow(this.id, this.arguments) : title = arguments['name']?.toString() ?? 'ProxyPin';
}

/// Floating windows of the web UI, stacked in one overlay entry above the main page.
class WebWindows {
  WebWindows._();

  static final Map<String, _WebWindow> _windows = {};
  static final List<String> _order = [];
  static int _nextId = 1;

  /// Windows live in a route (not a raw overlay entry) so dialogs opened later stack above them.
  static _WindowHostRoute? _host;

  /// Bumped on every change; the window layer listens to it.
  static final ValueNotifier<int> _revision = ValueNotifier(0);

  /// Called when a window closes (e.g. to forget a pending breakpoint editor).
  static void Function(String windowId, Map<String, dynamic> arguments)? onClosed;

  static WindowController create(String argumentsJson) {
    final decoded = jsonDecode(argumentsJson);
    final id = '${_nextId++}';
    _windows[id] = _WebWindow(id, decoded is Map ? Map<String, dynamic>.from(decoded) : {});
    return WindowController._(id);
  }

  static Iterable<String> where(bool Function(Map<String, dynamic> arguments) test) =>
      _windows.values.where((w) => test(w.arguments)).map((w) => w.id).toList();

  static void show(String id) {
    final window = _windows[id];
    if (window == null) return;
    window.visible = true;
    _order
      ..remove(id)
      ..add(id);
    final navigator = navigatorHelper.navigatorKey.currentState;
    if (navigator == null) return;
    if (_host == null) {
      _host = _WindowHostRoute();
      navigator.push(_host!);
    }
    _refresh();
  }

  static void close(String id) {
    final window = _windows.remove(id);
    _order.remove(id);
    if (window != null) onClosed?.call(id, window.arguments);
    if (_order.isEmpty) {
      final host = _host;
      _host = null;
      if (host != null && host.isActive) host.navigator?.removeRoute(host);
      return;
    }
    _refresh();
  }

  static void _focus(String id) {
    if (_order.isNotEmpty && _order.last == id) return;
    _order
      ..remove(id)
      ..add(id);
    _refresh();
  }

  static void _update(String id, void Function(_WebWindow window) change) {
    final window = _windows[id];
    if (window == null) return;
    change(window);
    _refresh();
  }

  static void _refresh() => _revision.value++;
}

/// Non-modal route holding the window layer: the page below stays interactive, the back key/Escape does not
/// pop it (windows close with their own button).
class _WindowHostRoute extends OverlayRoute<void> {
  final OverlayEntry layer = OverlayEntry(builder: (_) => const _WindowLayer());

  @override
  Iterable<OverlayEntry> createOverlayEntries() => [layer];

  @override
  RoutePopDisposition get popDisposition => RoutePopDisposition.doNotPop;
}

class _WindowLayer extends StatelessWidget {
  const _WindowLayer();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: WebWindows._revision,
      builder: (context, _, __) => _buildWindows(),
    );
  }

  Widget _buildWindows() {
    return LayoutBuilder(builder: (context, constraints) {
      final area = constraints.biggest;
      final windows = WebWindows._order.map((id) => WebWindows._windows[id]).whereType<_WebWindow>();
      return Stack(children: [
        for (final (index, window) in windows.indexed) _WindowFrame(key: window.key, window: window, area: area, cascade: index),
      ]);
    });
  }
}

class _WindowFrame extends StatefulWidget {
  final _WebWindow window;
  final Size area;
  final int cascade;

  const _WindowFrame({super.key, required this.window, required this.area, required this.cascade});

  @override
  State<_WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends State<_WindowFrame> {
  late final Widget _content = multiWindow(widget.window.id, Map<String, dynamic>.of(widget.window.arguments));

  @override
  Widget build(BuildContext context) {
    final window = widget.window;
    final area = widget.area;
    final compact = area.width < 700 || area.height < 500;

    final width = compact ? area.width : math.min(window.size.width, area.width - 24);
    final height = compact ? area.height : math.min(window.size.height, area.height - 24);
    var position = compact
        ? Offset.zero
        : (window.position ??
            Offset((area.width - width) / 2 + widget.cascade * 24, math.max(12, (area.height - height) / 2) + widget.cascade * 24));
    position = Offset(position.dx.clamp(0, math.max(0, area.width - width)), position.dy.clamp(0, math.max(0, area.height - 40)));

    final theme = Theme.of(context);
    return Positioned(
      left: position.dx,
      top: position.dy,
      width: width,
      height: height,
      child: Listener(
        onPointerDown: (_) => WebWindows._focus(window.id),
        child: Material(
          elevation: 14,
          borderRadius: BorderRadius.circular(compact ? 0 : 10),
          clipBehavior: Clip.antiAlias,
          color: theme.scaffoldBackgroundColor,
          child: Column(children: [
            GestureDetector(
              onPanUpdate: compact
                  ? null
                  : (details) => WebWindows._update(window.id, (w) => w.position = position + details.delta),
              child: Container(
                height: 32,
                padding: const EdgeInsets.only(left: 12),
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                child: Row(children: [
                  Expanded(
                      child: Text(window.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge)),
                  IconButton(
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    icon: const Icon(Icons.close),
                    onPressed: () => WebWindows.close(window.id),
                  ),
                ]),
              ),
            ),
            Expanded(
              child: Stack(children: [
                Positioned.fill(
                  child: Navigator(
                    key: window.navigatorKey,
                    onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, __, ___) => _content),
                  ),
                ),
                if (!compact)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onPanUpdate: (details) => WebWindows._update(
                          window.id,
                          (w) => w.size = Size(math.max(360, width + details.delta.dx), math.max(240, height + details.delta.dy))),
                      child: const MouseRegion(
                        cursor: SystemMouseCursors.resizeDownRight,
                        child: SizedBox(width: 16, height: 16, child: Icon(Icons.south_east, size: 12)),
                      ),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
