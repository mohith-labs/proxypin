/*
 * Smoke tests for the redesigned application screens.
 *
 * The component tests cover the design system in isolation; these pump the
 * REAL app widgets (the ones actually edited) so a glass change that renders
 * only in context — bad constraints inside a Scaffold, an unbounded height in
 * a Row, a missing Material ancestor — fails here instead of on a device.
 */
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/liquid/liquid.dart';
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/ui/component/selection_action_bar.dart';
import 'package:proxypin/ui/component/split_view.dart';

/// Mirrors the real app shell: glass theme + backdrop + localizations.
Widget app(Widget home, {Brightness brightness = Brightness.light}) {
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: brightness),
  );

  return MaterialApp(
    theme: LiquidGlassTheme.apply(base),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => GlassBackdrop(child: child ?? const SizedBox()),
    home: home,
  );
}

void main() {
  testWidgets('glass app bar + floating nav bar compose in a real Scaffold', (tester) async {
    var index = 0;

    await tester.pumpWidget(app(StatefulBuilder(builder: (context, setState) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        appBar: const LiquidGlassAppBar(title: Text('Requests')),
        body: ListView.builder(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: 30,
          itemBuilder: (context, i) => StaggeredEntrance(
            index: i,
            child: GlassSection(children: [
              GlassTile(title: Text('Row $i'), subtitle: const Text('200 · 1.2 K'), onTap: () {}),
            ]),
          ),
        ),
        bottomNavigationBar: LiquidGlassNavBar(
          currentIndex: index,
          onTap: (i) => setState(() => index = i),
          items: const [
            GlassNavItem(icon: Icons.swap_vert_circle_outlined, label: 'Requests'),
            GlassNavItem(icon: Icons.construction_outlined, label: 'Toolbox'),
            GlassNavItem(icon: Icons.tune_outlined, label: 'Config'),
            GlassNavItem(icon: Icons.settings_outlined, label: 'Setting'),
          ],
        ),
      );
    })));
    await tester.pumpAndSettle();

    expect(find.text('Requests'), findsWidgets);
    expect(find.text('Row 0'), findsOneWidget);

    // Scrolling under translucent chrome must not throw or overflow.
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();
    expect(index, 2);

    expect(tester.takeException(), isNull);
  });

  testWidgets('settings-style glass sections render in dark mode', (tester) async {
    await tester.pumpWidget(app(
      Scaffold(
        backgroundColor: Colors.transparent,
        appBar: const LiquidGlassAppBar(title: Text('Setting')),
        body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
          GlassSection(header: 'Proxy', children: [
            GlassTile(title: const Text('HTTPS Proxy'), onTap: () {}),
            GlassTile(
              title: const Text('SOCKS5'),
              showChevron: false,
              trailing: Switch(value: true, onChanged: (_) {}),
            ),
          ]),
          GlassSection(header: 'About', footer: 'ProxyPin', children: [
            GlassTile(title: const Text('Version'), trailing: const Text('1.3.3'), showChevron: false),
          ]),
        ]),
      ),
      brightness: Brightness.dark,
    ));
    await tester.pumpAndSettle();

    expect(find.text('PROXY'), findsOneWidget);
    expect(find.text('HTTPS Proxy'), findsOneWidget);
    expect(find.text('1.3.3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection action bar renders and cancels', (tester) async {
    final controller = MultiSelectController();
    controller.enterSelectionMode('req-1');

    await tester.pumpWidget(app(Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(children: [
        SelectionActionBar(
          selectionController: controller,
          onRepeat: () {},
          onExport: () {},
          onDelete: () {},
        ),
      ]),
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.repeat), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(controller.selectedIds.isEmpty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('split view divider drags and rubber-bands at its limits', (tester) async {
    double? ratio;

    await tester.pumpWidget(app(Scaffold(
      backgroundColor: Colors.transparent,
      body: VerticalSplitView(
        ratio: 0.3,
        minRatio: 0.15,
        maxRatio: 0.9,
        onRatioChanged: (r) => ratio = r,
        left: const ColoredBox(color: Colors.transparent, child: Center(child: Text('left'))),
        right: const ColoredBox(color: Colors.transparent, child: Center(child: Text('right'))),
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.text('left'), findsOneWidget);
    expect(find.text('right'), findsOneWidget);

    // Drag far past the maximum: rubberbanding must absorb it, not overflow.
    // Target the divider's own GestureDetector (the one wrapping the handle).
    final divider = find.descendant(
      of: find.byType(VerticalSplitView),
      matching: find.byType(GestureDetector),
    );
    expect(divider, findsWidgets);
    await tester.drag(divider.first, const Offset(5000, 0));
    await tester.pumpAndSettle();

    expect(ratio, isNotNull);
    expect(ratio!, lessThanOrEqualTo(1.0));
    expect(ratio!, greaterThan(0.3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass chrome survives a very narrow viewport', (tester) async {
    // Worst-case layout: a phone-width window with long unbroken text.
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(app(Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      appBar: const LiquidGlassAppBar(title: Text('Requests')),
      body: GlassSection(children: [
        GlassTile(
          title: const Text('https://example.com/a/very/long/path/that/will/not/fit/on/one/line?x=1&y=2'),
          subtitle: const Text('12:00:00 · 1.2 K / 48.0 K · 120ms'),
          onTap: () {},
        ),
      ]),
      bottomNavigationBar: LiquidGlassNavBar(
        currentIndex: 0,
        onTap: (_) {},
        showLabels: true,
        items: const [
          GlassNavItem(icon: Icons.swap_vert_circle_outlined, label: 'Requests'),
          GlassNavItem(icon: Icons.construction_outlined, label: 'Toolbox'),
          GlassNavItem(icon: Icons.tune_outlined, label: 'Config'),
          GlassNavItem(icon: Icons.settings_outlined, label: 'Setting'),
        ],
      ),
    )));
    await tester.pumpAndSettle();

    // A RenderFlex overflow would surface as an exception here.
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass sheet opens, shows its handle and dismisses', (tester) async {
    await tester.pumpWidget(app(Builder(builder: (context) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: GlassButton(
            onPressed: () => showGlassSheet(
              context,
              builder: (_) => const SizedBox(height: 200, child: Center(child: Text('sheet body'))),
            ),
            child: const Text('open sheet'),
          ),
        ),
      );
    })));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    expect(find.text('sheet body'), findsOneWidget);

    // Tap the barrier to dismiss.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('sheet body'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
