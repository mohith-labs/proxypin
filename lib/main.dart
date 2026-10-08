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

import 'dart:async';
import 'dart:convert';
import 'package:proxypin/utils/io.dart';

import 'package:flutter/material.dart';
import 'package:proxypin/ui/component/code_editor/code_forge_compat.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/manager/environment_manager.dart';
import 'package:proxypin/network/components/request_breakpoint.dart';
import 'package:proxypin/ui/component/chinese_font.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/desktop.dart';
import 'package:proxypin/ui/mobile/mobile.dart';
import 'package:proxypin/utils/desktop_support.dart';
import 'package:proxypin/utils/navigator.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

import 'l10n/app_localizations.dart';
import 'web/web_entry_stub.dart' if (dart.library.js_interop) 'web/web_app.dart' as web_entry;

///主入口
///@author wanghongen
void main(List<String> args) async {
  // 浏览器: 由 ProxyPin 服务端提供抓包引擎(反向代理), 这里只运行界面
  if (Platforms.isWeb) {
    await web_entry.runWebApp();
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  try {
    await RustLib.init();
  } catch (e) {
    // code_forge Rust FFI initialization may fail on iOS 14.x due to
    // deployment-target / cargokit-build incompatibilities. Degrade
    // gracefully instead of crashing the whole app at startup.
    print('RustLib.init failed: $e');
  }

  final windowController = Platforms.isDesktop() ? await DesktopMultiWindow.ensureInitialized() : null;

  var instance = AppConfiguration.instance;

  //多窗口
  if (args.firstOrNull == 'multi_window') {
    final windowId = windowController!.windowId;
    final argument =
        windowController.arguments.isEmpty ? const {} : jsonDecode(windowController.arguments) as Map<String, dynamic>;
    DesktopMultiWindow.initializeFromArguments(argument);
    var appConfiguration = await instance;

    if (Platform.isMacOS) {
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }
    if (appConfiguration.themeMode != ThemeMode.system) {
      windowManager.setBrightness(appConfiguration.themeMode == ThemeMode.dark ? Brightness.dark : Brightness.light);
    }
    runApp(FluentApp(multiWindow(windowId, argument), appConfiguration));
    return;
  }

  // 断点命中时打开断点执行窗口(移动端由 MultiWindow.onOpenWindow 推入页面)
  RequestBreakpointInterceptor.presenter = (hit) => MultiWindow.openWindow(
      hit.isResponse ? "Breakpoint - Response" : "Breakpoint - Request", 'BreakpointExecutor',
      args: hit.toWindowArgs());

  var configuration = Configuration.instance;
  // 预热环境变量,避免第一个请求命中时才 IO
  unawaited(EnvironmentManager.preload());
  //移动端
  if (Platforms.isMobile()) {
    var appConfiguration = await instance;
    runApp(FluentApp(MobileHomePage((await configuration), appConfiguration), appConfiguration));
    return;
  }

  var appConfiguration = await instance;
  if (Platforms.isDesktop()) {
    await DesktopSupport.initialize(appConfiguration);
  }

  runApp(FluentApp(DesktopHomePage(await configuration, appConfiguration), appConfiguration));
}

class FluentApp extends StatelessWidget {
  final Widget home;
  final AppConfiguration appConfiguration;

  const FluentApp(this.home, this.appConfiguration, {super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
        valueListenable: appConfiguration.globalChange,
        builder: (_, current, __) {
          return MaterialApp(
            title: 'ProxyPin',
            debugShowCheckedModeBanner: false,
            navigatorKey: navigatorHelper.navigatorKey,
            theme: theme(Brightness.light),
            darkTheme: theme(Brightness.dark),
            themeMode: appConfiguration.themeMode,
            locale: appConfiguration.language,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: home,
          );
        });
  }

  ThemeData theme(Brightness brightness) {
    bool useMaterial3 = appConfiguration.useMaterial3;
    bool isDark = brightness == Brightness.dark;

    Color? themeColor = isDark ? appConfiguration.themeColor : appConfiguration.themeColor;
    Color? cardColor = isDark ? Color(0XFF3C3C3C) : Colors.white;
    Color? surfaceContainer = isDark ? Colors.grey[800] : Colors.white;

    Color? secondary = useMaterial3 ? null : themeColor;
    if (themeColor is MaterialColor) {
      secondary = themeColor[500];
    }

    var colorScheme = ColorScheme.fromSeed(
      brightness: brightness,
      seedColor: themeColor,
      primary: themeColor,
      surface: cardColor,
      secondary: secondary,
      onPrimary: isDark ? Colors.white : null,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceContainer,
    );

    var themeData =
        ThemeData(brightness: brightness, useMaterial3: appConfiguration.useMaterial3, colorScheme: colorScheme);

    if (!appConfiguration.useMaterial3) {
      themeData = themeData.copyWith(
        appBarTheme: themeData.appBarTheme.copyWith(
          iconTheme: themeData.iconTheme.copyWith(size: 20),
          backgroundColor: themeData.canvasColor,
          elevation: 0,
          titleTextStyle: themeData.textTheme.titleMedium,
        ),
        tabBarTheme: themeData.tabBarTheme.copyWith(
          labelColor: themeData.colorScheme.primary,
          indicatorColor: themeColor,
          unselectedLabelColor: themeData.textTheme.titleMedium?.color,
        ),
      );
    }

    if (Platform.isWindows) {
      themeData = themeData.useSystemChineseFont();
    }

    return themeData.copyWith(
        dialogTheme:
            themeData.dialogTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
  }
}
