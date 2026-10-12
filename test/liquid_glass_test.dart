/*
 * Widget tests for the Liquid Glass design system.
 *
 * These actually pump the widgets, so they catch render-time failures that
 * static analysis cannot: bad constraints, missing ancestors, NaN geometry,
 * disposed controllers, and animations that never settle.
 */
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/component/liquid/liquid.dart';

/// Wraps a widget in the real app theme so tests exercise the production
/// ThemeData path (glass component themes, page transitions, backdrop).
Widget host(Widget child, {Brightness brightness = Brightness.light, Size? size}) {
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: brightness),
  );

  return MaterialApp(
    theme: LiquidGlassTheme.apply(base),
    home: GlassBackdrop(child: Scaffold(backgroundColor: Colors.transparent, body: Center(child: child))),
  );
}

void main() {
  group('GlassSurface', () {
    testWidgets('renders in light and dark without overflow', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(host(
          const GlassSurface(
            width: 200,
            height: 100,
            child: Center(child: Text('glass')),
          ),
          brightness: brightness,
        ));
        await tester.pumpAndSettle();

        expect(find.text('glass'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('applies a BackdropFilter when transparency is allowed', (tester) async {
      await tester.pumpWidget(host(const GlassSurface(width: 100, height: 50, child: SizedBox())));
      await tester.pumpAndSettle();

      expect(find.byType(BackdropFilter), findsWidgets);
    });

    testWidgets('drops the blur under reduced transparency (highContrast)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: LiquidGlassTheme.apply(ThemeData(useMaterial3: true)),
        home: const MediaQuery(
          data: MediaQueryData(highContrast: true),
          child: GlassSurface(width: 100, height: 50, child: SizedBox()),
        ),
      ));
      await tester.pumpAndSettle();

      // Accessibility: a frosted-but-solid fill replaces the translucency.
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every weight renders', (tester) async {
      for (final weight in GlassWeight.values) {
        await tester.pumpWidget(host(GlassSurface(weight: weight, width: 120, height: 60, child: const SizedBox())));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'weight $weight failed');
      }
    });
  });

  group('PressableGlass', () {
    testWidgets('fires onTap and reacts on pointer-DOWN, before release', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(PressableGlass(
        onTap: () => taps++,
        child: const SizedBox(width: 120, height: 48, child: Center(child: Text('press'))),
      )));
      await tester.pumpAndSettle();

      // The scale Transform owned by PressableGlass itself.
      Matrix4 pressTransform() => tester
          .widget<Transform>(
            find.descendant(of: find.byType(PressableGlass), matching: find.byType(Transform)).first,
          )
          .transform;

      final before = pressTransform().clone();

      // Press down and HOLD, never releasing. The first pump only starts the
      // ticker, so advance one more frame and assert the spring is already
      // moving — i.e. feedback begins ~16ms after touch, not on release.
      final gesture = await tester.startGesture(tester.getCenter(find.text('press')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(pressTransform(), isNot(equals(before)),
          reason: 'press feedback must start on pointer-down, not on release');
      expect(taps, 0, reason: 'tap must not have committed while still held');

      await gesture.up();
      await tester.pumpAndSettle();

      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('settles back after an interrupted press', (tester) async {
      await tester.pumpWidget(host(PressableGlass(
        onTap: () {},
        child: const SizedBox(width: 100, height: 40, child: Text('x')),
      )));

      final gesture = await tester.startGesture(tester.getCenter(find.text('x')));
      await tester.pump(const Duration(milliseconds: 30));
      // Drag away: the press should cancel, not commit.
      await gesture.moveBy(const Offset(300, 300));
      await gesture.up();
      await tester.pumpAndSettle();

      // pumpAndSettle throws if the spring never comes to rest.
      expect(tester.takeException(), isNull);
    });

    testWidgets('disabled pressable passes the child through untouched', (tester) async {
      await tester.pumpWidget(host(const PressableGlass(
        enabled: false,
        child: Text('inert'),
      )));
      await tester.pumpAndSettle();

      expect(find.text('inert'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('LiquidGlassNavBar', () {
    testWidgets('reports taps and springs the pill to the new index', (tester) async {
      var index = 0;
      await tester.pumpWidget(host(StatefulBuilder(builder: (context, setState) {
        return SizedBox(
          width: 400,
          child: LiquidGlassNavBar(
            currentIndex: index,
            onTap: (i) => setState(() => index = i),
            items: const [
              GlassNavItem(icon: Icons.list, label: 'One'),
              GlassNavItem(icon: Icons.build, label: 'Two'),
              GlassNavItem(icon: Icons.tune, label: 'Three'),
              GlassNavItem(icon: Icons.settings, label: 'Four'),
            ],
          ),
        );
      })));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();

      expect(index, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rapid retargeting never leaves a stuck animation', (tester) async {
      var index = 0;
      await tester.pumpWidget(host(StatefulBuilder(builder: (context, setState) {
        return SizedBox(
          width: 400,
          child: LiquidGlassNavBar(
            currentIndex: index,
            onTap: (i) => setState(() => index = i),
            items: const [
              GlassNavItem(icon: Icons.list, label: 'One'),
              GlassNavItem(icon: Icons.build, label: 'Two'),
              GlassNavItem(icon: Icons.tune, label: 'Three'),
              GlassNavItem(icon: Icons.settings, label: 'Four'),
            ],
          ),
        );
      })));

      // Interrupt each transition mid-flight — the spring must re-target.
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.byIcon(Icons.list));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.byIcon(Icons.build));
      await tester.pumpAndSettle();

      expect(index, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('controls', () {
    testWidgets('GlassButton filled and plain both tap', (tester) async {
      var filled = 0, plain = 0;
      await tester.pumpWidget(host(Column(mainAxisSize: MainAxisSize.min, children: [
        GlassButton(filled: true, onPressed: () => filled++, icon: Icons.check, child: const Text('Filled')),
        GlassButton(onPressed: () => plain++, child: const Text('Plain')),
      ])));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Filled'));
      await tester.tap(find.text('Plain'));
      await tester.pumpAndSettle();

      expect(filled, 1);
      expect(plain, 1);
    });

    testWidgets('GlassChip renders label and icon', (tester) async {
      await tester.pumpWidget(host(const GlassChip(label: 'GET', icon: Icons.download)));
      await tester.pumpAndSettle();

      expect(find.text('GET'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('GlassSection renders header, tiles and separators', (tester) async {
      var tapped = false;
      await tester.pumpWidget(host(SizedBox(
        width: 360,
        child: GlassSection(
          header: 'Group',
          footer: 'Explanation',
          children: [
            GlassTile(title: const Text('First'), onTap: () => tapped = true),
            const GlassTile(title: Text('Second'), subtitle: Text('detail')),
          ],
        ),
      )));
      await tester.pumpAndSettle();

      expect(find.text('GROUP'), findsOneWidget);
      expect(find.text('Explanation'), findsOneWidget);
      expect(find.text('detail'), findsOneWidget);
      // One inset hairline between two tiles.
      expect(find.byType(Divider), findsOneWidget);

      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });

  group('motion', () {
    testWidgets('StaggeredEntrance completes and shows its child', (tester) async {
      await tester.pumpWidget(host(Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(
          6,
          (i) => StaggeredEntrance(index: i, child: Text('row $i')),
        ),
      )));
      await tester.pumpAndSettle();

      expect(find.text('row 0'), findsOneWidget);
      expect(find.text('row 5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('PulsingGlow stops cleanly when deactivated', (tester) async {
      await tester.pumpWidget(host(const PulsingGlow(
        color: Colors.red,
        active: true,
        child: SizedBox(width: 40, height: 40),
      )));
      await tester.pump(const Duration(milliseconds: 300));

      // Toggling off must stop the repeat, otherwise pumpAndSettle times out.
      await tester.pumpWidget(host(const PulsingGlow(
        color: Colors.red,
        active: false,
        child: SizedBox(width: 40, height: 40),
      )));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('MaterializingGlass settles', (tester) async {
      await tester.pumpWidget(host(const MaterializingGlass(child: SizedBox(width: 200, height: 120))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion short-circuits entrance animation', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: LiquidGlassTheme.apply(ThemeData(useMaterial3: true)),
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: StaggeredEntrance(index: 5, child: Text('instant')),
          ),
        ),
      ));
      // No pumpAndSettle needed: under reduced motion the child is immediate.
      await tester.pump();

      expect(find.text('instant'), findsOneWidget);
    });
  });

  group('physics helpers', () {
    test('momentum projection grows with velocity and matches Apple model', () {
      expect(projectMomentum(0), 0);

      final slow = projectMomentum(500);
      final fast = projectMomentum(2000);
      expect(fast, greaterThan(slow));

      // (v/1000) * d / (1 - d) with d = 0.998 => v * 0.499
      expect(projectMomentum(1000), closeTo(499, 1));
      // Direction is preserved.
      expect(projectMomentum(-1000), closeTo(-499, 1));
    });

    test('rubberband resists progressively and never exceeds the overshoot', () {
      expect(rubberband(0, 100), 0);

      final small = rubberband(10, 100);
      final large = rubberband(100, 100);

      expect(small, lessThan(10), reason: 'resistance must damp the raw overshoot');
      expect(large, lessThan(100));
      // Further out => proportionally more resistance.
      expect(large / 100, lessThan(small / 10));
      expect(rubberband(-10, 100), lessThan(0));
    });

    test('springs are configured from response and damping ratio', () {
      final critical = GlassSprings.of(response: 0.4, dampingRatio: 1.0);
      final bouncy = GlassSprings.of(response: 0.4, dampingRatio: 0.7);

      // Same response => same stiffness; lower damping ratio => less damping.
      expect(critical.stiffness, closeTo(bouncy.stiffness, 0.001));
      expect(bouncy.damping, lessThan(critical.damping));

      // A faster response is a stiffer spring.
      expect(GlassSprings.of(response: 0.2).stiffness, greaterThan(critical.stiffness));
    });
  });

  group('theme', () {
    test('apply() keeps the colour scheme and makes scaffolds transparent', () {
      final base = ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.pink),
      );
      final themed = LiquidGlassTheme.apply(base);

      expect(themed.colorScheme.primary, base.colorScheme.primary);
      expect(themed.scaffoldBackgroundColor, Colors.transparent);
      // canvasColor must stay opaque or Material-2 drawers/dropdowns break.
      expect(themed.canvasColor, isNot(Colors.transparent));
      // Bottom sheets must stay opaque for the app's existing call sites.
      expect(themed.bottomSheetTheme.backgroundColor, isNot(Colors.transparent));
    });

    test('type tracking tightens as text grows', () {
      final t = LiquidGlassTheme.textTheme(ThemeData().textTheme);

      expect(t.displayLarge!.letterSpacing, lessThan(0));
      expect(t.titleMedium!.letterSpacing, lessThan(0));
      // Small text gets slightly positive tracking for legibility.
      expect(t.labelSmall!.letterSpacing, greaterThan(0));
      expect(t.displayLarge!.letterSpacing, lessThan(t.titleMedium!.letterSpacing!));
    });
  });

  group('transitions', () {
    testWidgets('GlassPageRoute pushes and pops along the same path', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: LiquidGlassTheme.apply(ThemeData(useMaterial3: true)),
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: GlassButton(
                onPressed: () => Navigator.of(context).push(
                  GlassPageRoute(page: const Scaffold(body: Center(child: Text('detail')))),
                ),
                child: const Text('open'),
              ),
            ),
          );
        }),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);

      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pop();
      await tester.pumpAndSettle();

      expect(find.text('detail'), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
