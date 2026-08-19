import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

/// Golden 基础设施自检（PR2）。
///
/// 只验证 harness 本身的行为，**不生成任何产品 Golden PNG**——
/// 第一张像素基线留给 PR3 起的产品页面 Golden。
void main() {
  const homeMarker = Key('harness-home');

  Widget harnessHome() => const SizedBox(key: homeMarker);

  setUpAll(() async {
    await loadTestFonts();
  });

  group('golden viewport', () {
    testWidgets('360×800 profile exposes MediaQuery 360×800', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(GoldenTestApp(home: harnessHome()));

      final context = tester.element(find.byKey(homeMarker));
      expect(MediaQuery.sizeOf(context), const Size(360, 800));
    });

    testWidgets('390×844 profile exposes MediaQuery 390×844', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      await tester.pumpWidget(GoldenTestApp(home: harnessHome()));

      final context = tester.element(find.byKey(homeMarker));
      expect(MediaQuery.sizeOf(context), const Size(390, 844));
    });

    testWidgets('cleanup restores default surface size', (tester) async {
      // 上一个测试通过 addTearDown 恢复：默认测试视图为 800×600 @ dpr 3.0。
      expect(tester.view.physicalSize, const Size(2400, 1800));
    });
  });

  group('text profile', () {
    test('large profile maps to TextScaler 1.3', () {
      expect(GoldenTextProfile.normal.scaler, TextScaler.noScaling);
      expect(GoldenTextProfile.large.scaler, const TextScaler.linear(1.3));
    });

    testWidgets('GoldenTestApp applies large text scaler', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(
        GoldenTestApp(
          home: harnessHome(),
          textScaler: GoldenTextProfile.large.scaler,
        ),
      );

      final context = tester.element(find.byKey(homeMarker));
      expect(MediaQuery.textScalerOf(context), const TextScaler.linear(1.3));
    });
  });

  group('GoldenTestApp shell', () {
    testWidgets('uses production light theme', (tester) async {
      await tester.pumpWidget(GoldenTestApp(home: harnessHome()));
      expect(
        Theme.of(tester.element(find.byKey(homeMarker))).brightness,
        Brightness.light,
      );
    });

    testWidgets('uses production dark theme', (tester) async {
      await tester.pumpWidget(
        GoldenTestApp(home: harnessHome(), themeMode: ThemeMode.dark),
      );

      expect(
        Theme.of(tester.element(find.byKey(homeMarker))).brightness,
        Brightness.dark,
      );
    });

    testWidgets('exposes zh-CN locale', (tester) async {
      await tester.pumpWidget(GoldenTestApp(home: harnessHome()));

      expect(
        Localizations.localeOf(tester.element(find.byKey(homeMarker))),
        const Locale('zh', 'CN'),
      );
    });

    testWidgets('disableAnimations propagates to MediaQuery', (tester) async {
      await tester.pumpWidget(
        GoldenTestApp(home: harnessHome(), disableAnimations: true),
      );

      final context = tester.element(find.byKey(homeMarker));
      expect(MediaQuery.disableAnimationsOf(context), isTrue);
    });
  });

  group('font loader', () {
    test('loads once and is idempotent', () async {
      final first = loadTestFonts();
      final second = loadTestFonts();
      expect(identical(first, second), isTrue);
      await first;
    });

    testWidgets('theme provides production CJK font family', (tester) async {
      await tester.pumpWidget(
        const GoldenTestApp(
          home: Text('渲染测试', style: TextStyle(fontSize: 16)),
        ),
      );

      final context = tester.element(find.text('渲染测试'));
      expect(Theme.of(context).textTheme.bodyMedium?.fontFamily, 'NotoSansCJKsc');
      expect(tester.takeException(), isNull);
    });
  });
}