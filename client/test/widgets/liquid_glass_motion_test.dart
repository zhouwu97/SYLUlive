import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_dynamics.dart';

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
}
