import 'package:bottom_nav_demo/main.dart';
import 'package:bottom_nav_demo/widgets/liquid_glass/liquid_glass_renderer.dart';
import 'package:bottom_nav_demo/widgets/liquid_glass/liquid_glass_dynamics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'same distance at different speeds produces different optical deformation',
    (tester) async {
      List<double> drag(double duration, {double hz = 120}) {
        final motion = LiquidGlassDynamics(vsync: tester)..configure(70);
        motion.grab();
        motion.advance(.5);
        var maxStretch = 0.0, maxBend = 0.0;
        final count = (duration * hz).round();
        for (var i = 1; i <= count; i++) {
          motion.dragTo(2.5 * i / count);
          motion.advance(1 / hz);
          if (motion.stretch > maxStretch) maxStretch = motion.stretch;
          if (motion.bend.dx > maxBend) maxBend = motion.bend.dx;
        }
        motion.dispose();
        return [maxStretch, maxBend];
      }

      final slow = drag(1.8), fast = drag(.18), sixtyHz = drag(.18, hz: 60);
      expect(fast[0], greaterThan(slow[0] * 2));
      expect(fast[1], greaterThan(slow[1] * 2));
      expect((fast[0] - sixtyHz[0]).abs(), lessThan(.025));
      final soft = LiquidGlassDynamics(vsync: tester)..grab(pressure: .65);
      final hard = LiquidGlassDynamics(vsync: tester)..grab(pressure: 1.16);
      soft.advance(1);
      hard.advance(1);
      expect(hard.pressure - soft.pressure, greaterThan(.45));
      soft.dispose();
      hard.dispose();
    },
  );

  testWidgets(
    'drag stretches, reverses and relaxes without lifting the finger',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const NavigationDemo());
      final dock = tester.getRect(
        find.byKey(const ValueKey('bottom-nav-floating-dock')),
      );
      final start = tester.getCenter(
        find.byKey(const ValueKey('bottom-nav-selection')),
      );
      LiquidGlassRenderer optics() =>
          tester.widget(find.byType(LiquidGlassRenderer));
      final gesture = await tester.startGesture(start);
      await tester.pump();
      for (var i = 0; i < 18; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      for (var i = 1; i <= 12; i++) {
        await gesture.moveTo(start + Offset(i * 17, -14));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(optics().bend.dx, greaterThan(3));
      expect(optics().stretch, greaterThan(.12));
      expect(optics().lens.center.dx, lessThan(start.dx + 204 - dock.left));
      // A held pointer is not a continuing force once the spring has caught up.
      await tester.pumpAndSettle();
      expect(optics().bend.distance, lessThan(.01));
      expect(optics().stretch.abs(), lessThan(.01));
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(start + Offset(204 - i * 16, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(optics().bend.dx, lessThan(-2));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(optics().bend.distance, lessThan(.01));
      expect(optics().press, lessThan(.001));
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );
}
