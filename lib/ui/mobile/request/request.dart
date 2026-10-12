/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import 'package:proxypin/utils/io.dart';

import 'package:date_format/date_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/network/util/cache.dart';
import 'package:proxypin/storage/favorites.dart';
import 'package:proxypin/ui/component/liquid/liquid.dart';
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/component/widgets.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/desktop/request/request.dart';
import 'package:proxypin/ui/mobile/request/repeat.dart';
import 'package:proxypin/utils/replay_task.dart';
import 'package:proxypin/ui/mobile/request/request_editor.dart';
import 'package:proxypin/ui/mobile/setting/request_rewrite.dart';
import 'package:proxypin/ui/mobile/setting/script.dart';
import 'package:proxypin/utils/curl.dart';
import 'package:proxypin/utils/keyword_highlight.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/utils/navigator.dart';
import 'package:shared_preferences/shared_preferences.dart';

///请求行
class RequestRow extends StatefulWidget {
  final int index;
  final HttpRequest request;
  final ProxyServer proxyServer;
  final bool displayDomain;
  final Function(HttpRequest)? onRemove;
  final MultiSelectController selectionController;
  final RequestSelectionHandlers selectionHandlers;
  final Function(VoidCallback refresh)? onMount; // 注册刷新回调
  final VoidCallback? onUnmount; // 注销刷新回调

  const RequestRow({
    super.key,
    required this.request,
    required this.proxyServer,
    this.displayDomain = true,
    this.onRemove,
    required this.selectionController,
    required this.index,
    required this.selectionHandlers,
    this.onMount,
    this.onUnmount,
  });

  @override
  State<StatefulWidget> createState() {
    return RequestRowState();
  }
}

class RequestRowState extends State<RequestRow> {
  static ExpiringCache<String, Image> imageCache = ExpiringCache<String, Image>(const Duration(minutes: 5));
  static const int maxAutoReadEntries = 5000;
  static LruCacheSet<String> autoReadRequests = LruCacheSet<String>(5000);

  static bool markAutoRead(String requestId) {
    return autoReadRequests.add(requestId);
  }

  static void removeAutoReadByIds(Iterable<String> requestIds) {
    autoReadRequests.removeAll(requestIds);
  }

  late HttpRequest request;
  HttpResponse? response;
  bool selected = false;
  Color? highlightColor; //高亮颜色

  AppLocalizations get localizations => AppLocalizations.of(availableContext)!;

  @override
  void initState() {
    request = widget.request;
    response = request.response;
    super.initState();
    // 注册响应刷新回调
    widget.onMount?.call(() {
      response = request.response;
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    widget.onUnmount?.call();
    super.dispose();
  }

  Color? color(String url) {
    if (highlightColor != null) {
      return highlightColor;
    }

    highlightColor = KeywordHighlights.getHighlightColor(url);
    if (highlightColor != null) {
      return highlightColor;
    }

    return autoReadRequests.contains(request.requestId) ? Colors.grey : null;
  }

  BuildContext getContext() => mounted ? super.context : NavigatorHelper().context;

  BuildContext get availableContext => getContext();

  @override
  Widget build(BuildContext context) {
    String url = widget.displayDomain ? request.requestUrl : request.path;
    var operationName = request.graphqlOperationName;
    final isMqtt = request.protocolVersion == 'MQTT';
    var title = isMqtt ? 'MQTT $url' : Strings.autoLineString(url);

    var time = formatDate(request.requestTime, [HH, ':', nn, ':', ss]);
    var contentType = response?.contentType.name.toUpperCase() ?? '';
    var packagesSize = getPackagesSize(request, response);

    var highlightColor = color(url);
    final theme = Theme.of(context);
    final palette = GlassPalette.of(context);
    final isSelected =
        selected || (widget.selectionController.isSelectionMode && widget.selectionController.contains(request.requestId));
    final statusCode = response?.status.code;

    // Subtitle: time · size · duration, with the status + type as chips above.
    final subTitle = isMqtt
        ? '$time · ${request.messages.length} packets'
        : '$time · $packagesSize${response?.costTime() ?? ''}';

    return PressableGlass(
      // Instant feedback on press-down; a glass row should feel physical.
      pressedScale: 0.985,
      borderRadius: BorderRadius.circular(GlassRadius.sm),
      onLongPressStart: menu,
      onTap: () {
        if (widget.selectionController.isSelectionMode) {
          widget.selectionController.toggle(request.requestId);
          return;
        }

        if (AppConfiguration.current?.autoReadEnabled == true) {
          if (markAutoRead(request.requestId)) {
            setState(() {});
          }
        }

        Navigator.of(getContext()).push(GlassPageRoute(
            page: NetworkTabController(
                proxyServer: widget.proxyServer,
                httpRequest: request,
                httpResponse: response,
                title: Text(localizations.captureDetail, style: const TextStyle(fontSize: 16)))));
      },
      child: AnimatedContainer(
        duration: GlassDuration.fast,
        curve: GlassCurves.standard,
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: palette.isDark ? 0.18 : 0.10)
              : (palette.isDark ? Colors.white.withValues(alpha: 0.045) : Colors.white.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(GlassRadius.sm),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary.withValues(alpha: 0.45)
                : palette.hairline,
            width: isSelected ? 1.1 : 0.7,
          ),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.selectionController.isSelectionMode) ...[
            _selectionCheckbox(),
            const SizedBox(width: 8),
          ],
          if (appIcon() != null) ...[
            SizedBox(width: 34, child: appIcon()),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Status chips: method + response code read at a glance.
              Row(children: [
                GlassChip(
                  label: isMqtt ? 'MQTT' : request.method.name,
                  color: _methodColor(request.method.name, theme),
                ),
                const SizedBox(width: 5),
                if (statusCode != null)
                  // Filled, so it never reads as a twin of the method chip
                  // even when both resolve to the same hue (GET + 200).
                  GlassChip(label: '$statusCode', color: _statusColor(statusCode), filled: true)
                else
                  // Still in flight — a quiet pulsing dot, not a spinner.
                  _PendingPulse(color: theme.colorScheme.primary),
                if (contentType.isNotEmpty) ...[
                  const SizedBox(width: 5),
                  GlassChip(label: contentType, color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
                ],
                const Spacer(),
                Text('#${widget.index}',
                    style: TextStyle(fontSize: 10.5, color: theme.colorScheme.onSurface.withValues(alpha: 0.35))),
              ]),
              const SizedBox(height: 6),
              Text.rich(
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                TextSpan(
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.3,
                    letterSpacing: -0.15,
                    fontWeight: FontWeight.w500,
                    color: highlightColor ?? theme.colorScheme.onSurface.withValues(alpha: 0.92),
                  ),
                  children: [
                    TextSpan(text: title.fixAutoLines()),
                    if (operationName != null) graphqlOperationSpan(request, fontSize: 13.5, fixAutoLines: true)!,
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.1,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: isMqtt
                ? const Icon(Icons.hub_outlined, color: Colors.teal, size: 18)
                : getIcon(response, color: highlightColor),
          ),
        ]),
      ),
    );
  }

  /// Animated check box for multi-select mode.
  Widget _selectionCheckbox() {
    bool isSelected = widget.selectionController.contains(request.requestId);
    return GlassAnimatedSwitcher(
      axis: Axis.horizontal,
      child: Icon(
        isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
        key: ValueKey(isSelected),
        size: 21,
        color: isSelected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
      ),
    );
  }

  /// Method colours: mutating verbs warm, reads cool.
  static Color _methodColor(String method, ThemeData theme) {
    switch (method.toUpperCase()) {
      case 'GET':
        return const Color(0xFF34A0A4);
      case 'POST':
        return const Color(0xFF3A86FF);
      case 'PUT':
      case 'PATCH':
        return const Color(0xFFD9822B);
      case 'DELETE':
        return const Color(0xFFE5484D);
      default:
        return theme.colorScheme.onSurface.withValues(alpha: 0.6);
    }
  }

  /// HTTP status colours: 2xx green, 3xx blue, 4xx amber, 5xx red.
  static Color _statusColor(int code) {
    if (code < 0) return const Color(0xFFE5484D);
    if (code < 300) return const Color(0xFF2EA043);
    if (code < 400) return const Color(0xFF3A86FF);
    if (code < 500) return const Color(0xFFD9822B);
    return const Color(0xFFE5484D);
  }

  Widget? rowLeading() {
    var icon = appIcon();
    if (!widget.selectionController.isSelectionMode) {
      return icon;
    }

    bool isSelected = widget.selectionController.contains(request.requestId);
    var checkbox = Icon(isSelected ? Icons.check_box_outlined : Icons.check_box_outline_blank_outlined,
        size: 20, color: isSelected ? Theme.of(context).colorScheme.primary : null);

    if (icon == null) {
      return checkbox;
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [checkbox, const SizedBox(width: 6), icon]);
  }

  Widget? appIcon() {
    if (Platform.isIOS) {
      return null;
    }
    if (request.processInfo == null) {
      return const Icon(Icons.question_mark, size: 38);
    }

    //如果有缓存图标直接返回图标
    if (request.processInfo!.hasCacheIcon) {
      return imageCache.putIfAbsent(request.processInfo!.id, () {
        return Image.memory(request.processInfo!.cacheIcon!, width: 40, gaplessPlayback: true);
      });
    }

    return FutureBuilder(
        future: request.processInfo!.getIcon(),
        builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
          if (snapshot.hasData) {
            return Image.memory(snapshot.data!, width: 40);
          }
          return const SizedBox(width: 40);
        });
  }

  ///菜单
  void menu(LongPressStartDetails details) {
    setState(() {
      selected = true;
    });

    var globalPosition = details.globalPosition;
    MediaQueryData mediaQuery = MediaQuery.of(context);
    var position = RelativeRect.fromLTRB(globalPosition.dx, globalPosition.dy, globalPosition.dx, globalPosition.dy);
    final selectionMode = widget.selectionController.isSelectionMode;
    // Trigger haptic feedback
    if (Platform.isAndroid) HapticFeedback.mediumImpact();

    showMenu(
        context: context,
        constraints: BoxConstraints(maxWidth: mediaQuery.size.width * 0.88),
        position: position,
        items: [
          PopupMenuContainer(
              child: Column(
            children: selectionMode
                ? [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                          padding: EdgeInsets.only(left: 20, top: 5),
                          child: Text(localizations.selectAction, style: Theme.of(context).textTheme.bodyLarge)),
                    ),
                    menuItem(
                      left: itemButton(
                          onPressed: () {
                            widget.selectionHandlers.onExportSelected?.call();
                            Navigator.maybePop(availableContext);
                          },
                          label: localizations.export,
                          icon: Icons.checklist_rtl_outlined),
                      right: itemButton(
                          onPressed: () {
                            widget.selectionHandlers.onRepeatSelected?.call();
                            Navigator.maybePop(availableContext);
                          },
                          label: localizations.repeat,
                          icon: Icons.delete_outline),
                    ),
                    SizedBox(height: 1),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      itemButton(
                          onPressed: () {
                            widget.selectionHandlers.onDeleteSelected?.call();
                            Navigator.maybePop(availableContext);
                          },
                          label: localizations.delete,
                          icon: Icons.delete_outline),
                      SizedBox(width: 15),
                    ]),
                  ]
                : [
                    //复制url
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                          padding: EdgeInsets.only(left: 20, top: 5),
                          child: Text(localizations.selectAction, style: Theme.of(context).textTheme.bodyLarge)),
                    ),
                    //copy
                    menuItem(
                      left: itemButton(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: request.requestUrl)).then((value) {
                              FlutterToastr.show(localizations.copied, getContext());
                              Navigator.maybePop(getContext());
                            });
                          },
                          label: localizations.copyUrl,
                          icon: Icons.link,
                          iconSize: 22),
                      right: itemButton(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: curlRequest(request))).then((value) {
                              FlutterToastr.show(localizations.copied, getContext());
                              Navigator.maybePop(getContext());
                            });
                          },
                          label: localizations.copyCurl,
                          icon: Icons.code),
                    ),
                    //repeat
                    menuItem(
                      left: itemButton(
                          onPressed: () {
                            onRepeat(request);
                            Navigator.maybePop(getContext());
                          },
                          label: localizations.repeat,
                          icon: Icons.repeat_one),
                      right: itemButton(
                          onPressed: () => showCustomRepeat(request),
                          label: localizations.customRepeat,
                          icon: Icons.repeat),
                    ),
                    //favorite and edit
                    menuItem(
                      left: itemButton(
                          onPressed: () {
                            FavoriteStorage.addFavorite(widget.request);
                            FlutterToastr.show(localizations.addSuccess, availableContext);
                            Navigator.maybePop(availableContext);
                          },
                          label: localizations.favorite,
                          icon: Icons.favorite_outline),
                      right: itemButton(
                          onPressed: () async {
                            await Navigator.maybePop(availableContext);

                            var pageRoute = MaterialPageRoute(
                                builder: (context) =>
                                    MobileRequestEditor(request: widget.request, proxyServer: widget.proxyServer));
                            Navigator.push(getContext(), pageRoute);
                          },
                          label: localizations.editRequest,
                          icon: Icons.replay_outlined),
                    ),
                    //script and rewrite
                    menuItem(
                      left: itemButton(
                          onPressed: () async {
                            Navigator.maybePop(availableContext);

                            var scriptManager = await ScriptManager.instance;
                            var url = request.domainPath;
                            var scriptItem = scriptManager.list.firstWhereOrNull((it) => it.urls.contains(url));
                            String? script = scriptItem == null ? null : await scriptManager.getScript(scriptItem);

                            var pageRoute = MaterialPageRoute(
                                builder: (context) => ScriptEdit(
                                    scriptItem: scriptItem,
                                    script: script,
                                    urls: scriptItem?.urls ?? [url],
                                    title: request.hostAndPort?.host));

                            Navigator.push(getContext(), pageRoute);
                          },
                          label: localizations.script,
                          icon: Icons.javascript_outlined),
                      right: itemButton(
                          onPressed: () async {
                            Navigator.maybePop(availableContext);
                            bool isRequest = response == null;
                            var requestRewrites = await RequestRewriteManager.instance;

                            var ruleType = isRequest ? RuleType.requestReplace : RuleType.responseReplace;
                            var rule = requestRewrites.getRequestRewriteRule(request, ruleType);

                            var rewriteItems = await requestRewrites.getRewriteItems(rule);

                            var pageRoute = MaterialPageRoute(
                                builder: (_) => RewriteRule(rule: rule, items: rewriteItems, request: request));
                            var context = availableContext;
                            if (context.mounted) Navigator.push(context, pageRoute);
                          },
                          label: localizations.requestRewrite,
                          icon: Icons.edit_outlined),
                    ),
                    menuItem(
                      left: itemButton(
                          onPressed: () {
                            highlightColor = Theme.of(availableContext).colorScheme.primary;
                            Navigator.maybePop(availableContext);
                          },
                          label: localizations.highlight,
                          icon: Icons.highlight_outlined),
                      right: itemButton(
                          onPressed: () {
                            AppConfiguration.current?.autoReadEnabled = !AppConfiguration.current!.autoReadEnabled;
                            highlightColor = Colors.grey;
                            Navigator.maybePop(availableContext);
                          },
                          label: localizations.autoRead,
                          icon: AppConfiguration.current?.autoReadEnabled == true
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank_outlined),
                    ),
                    SizedBox(height: 1),
                    menuItem(
                      left: itemButton(
                          onPressed: () {
                            widget.selectionController.toggle(request.requestId);
                            Navigator.maybePop(availableContext);
                          },
                          label: localizations.select,
                          icon: Icons.checklist_rtl_outlined),
                      right: itemButton(
                          onPressed: () {
                            widget.onRemove?.call(request);
                            FlutterToastr.show(localizations.deleteSuccess, availableContext);
                            Navigator.maybePop(availableContext);
                          },
                          label: localizations.delete,
                          icon: Icons.delete_outline),
                    ),
                  ],
          )),
        ]).then((value) {
      selected = false;
      if (mounted) setState(() {});
    });
  }

  //显示高级重发
  Future<void> showCustomRepeat(HttpRequest request) async {
    await Navigator.maybePop(availableContext);
    var pageRoute = MaterialPageRoute(
        builder: (context) => futureWidget(SharedPreferences.getInstance(),
            (prefs) => MobileCustomRepeat(
                onScheduled: (cfg) =>
                    ReplayTaskManager.instance.start(request: request, action: () => onRepeat(request), config: cfg),
                prefs: prefs)));

    Navigator.push(getContext(), pageRoute);
  }

  void onRepeat(HttpRequest request) {
    var httpRequest = request.copy(uri: request.requestUrl);
    var proxyInfo = widget.proxyServer.isRunning ? ProxyInfo.of("127.0.0.1", widget.proxyServer.port) : null;
    HttpClients.proxyRequest(httpRequest, proxyInfo: proxyInfo);

    if (mounted) {
      FlutterToastr.show(localizations.reSendRequest, context);
    }
  }

  Widget itemButton(
      {required String label, required IconData icon, required Function() onPressed, double iconSize = 20}) {
    var theme = Theme.of(context);
    var style = theme.textTheme.bodyMedium;
    return TextButton.icon(
        onPressed: onPressed,
        label: Text(label, style: style),
        icon: Icon(icon, size: iconSize, color: theme.colorScheme.primary.withValues(alpha: 0.65)));
  }

  Widget menuItem({required Widget left, required Widget right}) {
    return Row(
      children: [
        SizedBox(width: 130, child: Align(alignment: Alignment.centerLeft, child: left)),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: right))
      ],
    );
  }
}

/// In-flight indicator: a slow breathing dot. Communicates "waiting" without
/// the visual noise (or the constant repaint) of a spinner in a long list.
class _PendingPulse extends StatefulWidget {
  final Color color;

  const _PendingPulse({required this.color});

  @override
  State<_PendingPulse> createState() => _PendingPulseState();
}

class _PendingPulseState extends State<_PendingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (GlassAccessibility.reduceMotion(context)) {
      return GlassChip(label: '···', color: widget.color);
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Container(
          width: 20,
          height: 15,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.08 + 0.10 * t),
            borderRadius: BorderRadius.circular(GlassRadius.xs * 0.7),
          ),
          child: Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.45 + 0.45 * t),
            ),
          ),
        );
      },
    );
  }
}
