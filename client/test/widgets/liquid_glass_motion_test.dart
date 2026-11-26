import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_dynamics.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_scene.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_switch.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_tilt.dart';
import 'package:shenliyuan/widgets/settings/settings_switch.dart';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final on in [false, true]) {
    testWidgets('switch reverses immediately after dragging beyond rail on=$on',
        (tester) async {
      await tester.runAsync(loadLiquidGlassSwitchProgram);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var value = on;
      final commits = <bool>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LiquidGlassScene(
          background: const ColoredBox(color: Colors.white),
          overlay: ListView(controller: scroll, children: [
            StatefulBuilder(
                builder: (context, setState) => Center(
                      child: SettingsSwitch(
                          value: value,
                          onChanged: (next) {
                            commits.add(next);
                            setState(() => value = next);
                          }),
                    )),
            const SizedBox(height: 1600),
          ]),
        )),
      ));
      await tester.pumpAndSettle();
      final custom = find.descendant(
          of: find.byType(LiquidGlassSwitch),
          matching: find.byWidgetPredicate((w) =>
              w is CustomPaint &&
              w.painter.runtimeType.toString() == '_SwitchPainter'));
      final dynamic painter = tester.widget<CustomPaint>(custom.first).painter;
      final motion = painter.motion as LiquidGlassDynamics;
      final direction = on ? -1.0 : 1.0;
      final drag =
          await tester.startGesture(tester.getCenter(find.byType(Switch)));
      await tester.pump(const Duration(milliseconds: 200));
      await drag.moveBy(Offset(5 * direction, 0));
      await tester.pump(const Duration(milliseconds: 50));
      expect(motion.position, closeTo(on ? .75 : .25, .02),
          reason: 'A resting thumb previews small movements before drag slop');
      await drag.moveBy(Offset(105 * direction, 0));
      await tester.pump(const Duration(milliseconds: 80));
      expect(motion.position, closeTo(on ? 0 : 1, .01));
      for (var reversal = 0; reversal < 4; reversal++) {
        await drag.moveBy(Offset((reversal.isEven ? -24 : 24) * direction, 0));
        await tester.pump(const Duration(milliseconds: 50));
        final endpoint = reversal.isEven ? (on ? 1 : 0) : (on ? 0 : 1);
        expect(motion.position, closeTo(endpoint, .02),
            reason:
                'Excess travel outside the rail must not create a dead zone');
        expect(motion.pressure, greaterThan(.9));
        expect(commits, isEmpty);
        expect(scroll.offset, 0);
      }
      await drag.up();
      await tester.pumpAndSettle();
      expect(commits, [!on]);
      expect(value, !on);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'repress during guided switch travel keeps the visible lens moving',
      (tester) async {
    await tester.runAsync(loadLiquidGlassSwitchProgram);
    var value = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LiquidGlassScene(
      background: const ColoredBox(color: Colors.white),
      overlay: Center(
          child: StatefulBuilder(
              builder: (context, setState) => SettingsSwitch(
                  value: value,
                  onChanged: (next) => setState(() => value = next)))),
    ))));
    await tester.pumpAndSettle();
    final custom = find.descendant(
        of: find.byType(LiquidGlassSwitch),
        matching: find.byWidgetPredicate((w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_SwitchPainter'));
    final dynamic painter = tester.widget<CustomPaint>(custom.first).painter;
    final motion = painter.motion as LiquidGlassDynamics;
    await tester.tap(find.byType(Switch));
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final before = motion.position;
    expect(before, inExclusiveRange(.05, .7));
    final repress =
        await tester.startGesture(tester.getCenter(find.byType(Switch)));
    await repress.moveBy(const Offset(1, 1));
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(motion.position, greaterThan(before + .1),
        reason:
            'A new tap must not brake the previous journey before pointer-up');
    await repress.up();
    await tester.pumpAndSettle();
    expect(value, isFalse);
    expect(motion.position, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('regrabbing a moving switch decelerates without losing momentum',
      (tester) async {
    final motion = LiquidGlassDynamics(vsync: tester, directFollowRate: 100)
      ..configure(20);
    try {
      motion.grab();
      motion.dragTo(1);
      motion.advance(.01);
      final position = motion.position;
      final speed = motion.speed;
      motion.grab();
      expect(motion.speed, speed);
      motion.advance(.001);
      expect(motion.position, greaterThan(position));
      expect(motion.speed, greaterThan(speed * .1));
    } finally {
      motion.dispose();
    }
  });

  for (final scenario in ['diagonal reversal', 'late saved value']) {
    testWidgets('held switch keeps gesture ownership: $scenario',
        (tester) async {
      await tester.runAsync(loadLiquidGlassSwitchProgram);
      final value = ValueNotifier(false);
      addTearDown(value.dispose);
      var commits = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: LiquidGlassScene(
        background: const ColoredBox(color: Colors.white),
        overlay: Center(
            child: ValueListenableBuilder<bool>(
          valueListenable: value,
          builder: (context, current, child) => SettingsSwitch(
            value: current,
            onChanged: (_) => commits++,
          ),
        )),
      ))));
      await tester.pumpAndSettle();
      final toggle = find.byType(Switch);
      final custom = find.descendant(
          of: find.byType(LiquidGlassSwitch),
          matching: find.byWidgetPredicate((w) =>
              w is CustomPaint &&
              w.painter.runtimeType.toString() == '_SwitchPainter'));
      final dynamic painter = tester.widget<CustomPaint>(custom.first).painter;
      final motion = painter.motion as LiquidGlassDynamics;
      final center = tester.getCenter(toggle);
      final drag = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 300));
      await drag.moveTo(center + const Offset(32, 0));
      await tester.pump(const Duration(milliseconds: 60));
      if (scenario == 'diagonal reversal') {
        await drag.moveTo(center + const Offset(4, 24));
        await tester.pump(const Duration(milliseconds: 80));
        await drag.moveTo(center + const Offset(32, 24));
      } else {
        value.value = true;
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(commits, 0);
      expect(motion.pressure, greaterThan(.8));
      expect(motion.position, greaterThan(.8));
      await drag.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final hz in [60, 120]) {
    for (final on in [false, true]) {
      testWidgets(
          'resting switch keeps lift, travel and release at $hz Hz on=$on',
          (tester) async {
        final motion = LiquidGlassDynamics(
            vsync: tester, index: on ? 1 : 0, directFollowRate: 100)
          ..configure(20);
        addTearDown(motion.dispose);
        motion.grab();
        motion.tapTo(on ? 0 : 1);
        var lifted = false, arrived = false, shrank = false;
        var previous = 0.0;
        for (var frame = 0; frame < hz * 2 && motion.isMoving; frame++) {
          motion.advance(1 / hz);
          final travel = on ? 1 - motion.position : motion.position;
          expect(travel, greaterThanOrEqualTo(previous - .001));
          lifted |= travel < .02 && motion.pressure >= .8;
          arrived |= travel > .94 && motion.pressure >= .9;
          if (arrived && motion.pressure < .5) {
            expect(travel, greaterThan(.97));
            shrank = true;
          }
          previous = travel;
        }
        expect(lifted && arrived && shrank, isTrue);
        expect(motion.isMoving, isFalse);
        expect(motion.position, on ? 0 : 1);
        expect(motion.pressure, 0);
      });

      testWidgets(
          'rapid switch retap continues without another lift at $hz Hz on=$on',
          (tester) async {
        for (final elapsed in [.18, .3, .42, .6]) {
          final motion = LiquidGlassDynamics(
              vsync: tester, index: on ? 1 : 0, directFollowRate: 100)
            ..configure(20);
          addTearDown(motion.dispose);
          motion.grab();
          motion.advance(.02);
          motion.tapTo(on ? 0 : 1);
          for (var frame = 0; frame < (elapsed * hz).round(); frame++) {
            motion.advance(1 / hz);
          }
          final pose = (
            motion.position,
            motion.pressure,
            motion.speed,
            motion.stretch,
            motion.bend
          );
          motion.grab();
          expect((
            motion.position,
            motion.pressure,
            motion.speed,
            motion.stretch,
            motion.bend
          ), pose);
          motion.advance(.02);
          final endpoint = on ? 1.0 : 0.0;
          final distance = (motion.position - endpoint).abs();
          motion.tapTo(endpoint);
          for (var frame = 0; frame < hz ~/ 10; frame++) {
            motion.advance(1 / hz);
          }
          expect((motion.position - endpoint).abs(), lessThan(distance * .85),
              reason:
                  'Retapping at $elapsed s must resume toward the new end within 100 ms');
          motion.advance(2);
          expect(motion.isMoving, isFalse);
          expect(motion.position, endpoint);
          expect(motion.pressure, 0);
        }
      });

      testWidgets('held fast drag follows and reverses at $hz Hz on=$on',
          (tester) async {
        final motion = LiquidGlassDynamics(
            vsync: tester, index: on ? 1 : 0, directFollowRate: 100)
          ..configure(20);
        addTearDown(motion.dispose);
        motion.grab();
        motion.advance(1);
        final frames = (hz * .05).round();
        for (var i = 1; i <= frames; i++) {
          motion.dragTo(on ? 1 - i / frames : i / frames);
          motion.advance(1 / hz);
        }
        final destination = on ? 0.0 : 1.0;
        expect((destination - motion.position).abs() * 20, lessThan(3));
        final beforeReversal = motion.position;
        motion.dragTo(on ? 1 : 0);
        motion.advance(1 / hz);
        expect((motion.position - (on ? 1 : 0)).abs(),
            lessThan((beforeReversal - (on ? 1 : 0)).abs()));
        motion.snapTo(0);
      });
    }
  }

  testWidgets('switch animation does not repaint its settings card',
      (tester) async {
    await tester.runAsync(loadLiquidGlassSwitchProgram);
    var paints = 0;
    var value = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LiquidGlassScene(
          background: const ColoredBox(color: Colors.white),
          overlay: Center(
            child: CustomPaint(
              painter: _CountPaints(() => paints++),
              child: StatefulBuilder(builder: (context, setState) {
                return SettingsSwitch(
                  value: value,
                  onChanged: (next) => setState(() => value = next),
                );
              }),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    final initialPaints = paints;
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(paints, initialPaints);
    expect(value, isTrue);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (name, dark, reduced, contrast, enabled, capture) in [
    ('light', false, false, false, true, true),
    ('dark', true, false, false, true, true),
    ('reduced motion', false, true, false, true, true),
    ('high contrast', false, false, true, true, true),
    ('disabled', false, false, false, false, true),
    ('unavailable capture', false, false, false, true, false),
  ]) {
    testWidgets('native switch commits, cancellation and semantics: $name',
        (tester) async {
      await tester.runAsync(loadLiquidGlassSwitchProgram);
      final semantics = tester.ensureSemantics();
      final value = ValueNotifier(false);
      addTearDown(value.dispose);
      final commits = <bool>[];
      try {
        await tester.pumpWidget(MaterialApp(
          theme:
              ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(
                disableAnimations: reduced, highContrast: contrast),
            child: Scaffold(
              body: LiquidGlassScope(
                child: Stack(fit: StackFit.expand, children: [
                  if (capture)
                    const LiquidGlassBackground(
                        child: ColoredBox(color: Colors.white)),
                  Center(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: value,
                      builder: (context, current, child) => SettingsSwitch(
                        value: current,
                        onChanged: enabled
                            ? (next) {
                                commits.add(next);
                                value.value = next;
                              }
                            : null,
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final toggle = find.byType(Switch);
        for (var tap = 0; tap < 8; tap++) {
          await tester.tap(toggle);
          await tester.pump(const Duration(milliseconds: 60));
        }
        await tester.pumpAndSettle();
        expect(commits, enabled ? List.generate(8, (i) => i.isEven) : isEmpty);
        final state = tester.getSemantics(toggle).getSemanticsData();
        expect(state.flagsCollection.isToggled, ui.Tristate.isFalse);
        expect(state.flagsCollection.isEnabled,
            enabled ? ui.Tristate.isTrue : ui.Tristate.isFalse);
        if (name == 'light') {
          final drag = await tester.startGesture(tester.getCenter(toggle));
          await drag.moveBy(const Offset(35, 0));
          await tester.pump(const Duration(milliseconds: 80));
          expect(commits, hasLength(8));
          await drag.up();
          await tester.pumpAndSettle();
          expect(commits, hasLength(9));
          expect(commits.last, isTrue);
          final cancel = await tester.startGesture(tester.getCenter(toggle));
          await cancel.moveBy(const Offset(0, 35));
          await tester.pump(const Duration(milliseconds: 80));
          await cancel.cancel();
          await tester.pumpAndSettle();
          expect(commits, hasLength(9));
          expect(value.value, isTrue);
        }
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  testWidgets(
    'navigation elasticity increases strain and recoil without slowing tracking',
    (tester) async {
      final original = LiquidGlassDynamics(vsync: tester)..configure(70);
      final elastic = LiquidGlassDynamics(vsync: tester, shapeElasticity: 1.35)
        ..configure(70);
      try {
        for (final motion in [original, elastic]) {
          motion.grab();
          motion.advance(.5);
        }
        final peaks = [0.0, 0.0];
        final recoil = [0.0, 0.0];
        for (var frame = 1; frame <= 18; frame++) {
          for (final (i, motion) in [original, elastic].indexed) {
            motion.dragTo(2.5 * frame / 18);
            motion.advance(1 / 120);
            if (motion.stretch > peaks[i]) peaks[i] = motion.stretch;
          }
          expect(elastic.position, original.position);
        }
        original.releaseTo(2.5);
        elastic.releaseTo(2.5);
        for (var frame = 0; frame < 60; frame++) {
          for (final (i, motion) in [original, elastic].indexed) {
            motion.advance(1 / 120);
            if (frame >= 24) recoil[i] += motion.energy;
          }
          expect(elastic.position, original.position);
          expect(elastic.pressure, original.pressure);
        }
        expect(peaks[1], greaterThan(peaks[0] * 1.15));
        expect(recoil[1], greaterThan(recoil[0] * 1.4));
        elastic.advance(3);
        expect(elastic.isMoving, isFalse);
        expect(elastic.position, 2.5);
        expect(elastic.energy, 0);
      } finally {
        original.dispose();
        elastic.dispose();
      }
    },
  );

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
    'overlapping LiquidGlassTilt instances share one native gravity stream',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const capChannel = MethodChannel('liquid_glass/capabilities');
      const gravityChannel = MethodChannel('liquid_glass/gravity');
      var listenCount = 0;
      var cancelCount = 0;
      var active = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        capChannel,
        (call) async => call.method == 'gravity',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        gravityChannel,
        (call) async {
          if (call.method == 'listen') {
            listenCount++;
            active = true;
          } else if (call.method == 'cancel') {
            if (!active) {
              throw PlatformException(
                code: 'error',
                message: 'No active stream to cancel',
              );
            }
            active = false;
            cancelCount++;
          }
          return null;
        },
      );
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(capChannel, null);
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(gravityChannel, null);
      });

      final first = LiquidGlassTilt();
      final second = LiquidGlassTilt();
      try {
        await tester.pump();
        first.dispose();
        await tester.pump();
        expect(cancelCount, 0);
        second.dispose();
        await tester.pump();

        expect(listenCount, 1);
        expect(cancelCount, 1);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

class _CountPaints extends CustomPainter {
  _CountPaints(this.onPaint);
  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(_CountPaints oldDelegate) => false;
}
