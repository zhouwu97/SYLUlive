import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/appearance_settings_screen.dart';
import 'package:shenliyuan/widgets/settings/campus_segmented_control.dart';

import '../../helpers/golden_test_app.dart';
import '../../helpers/load_test_fonts.dart';

class _FailingStore extends MemoryPreferencesStore {
  bool fail = true;
  Completer<void>? pending;

  @override
  Future<bool> setBool(String key, bool value) async {
    final shouldFail = fail;
    final waiting = pending;
    pending = null;
    if (waiting != null) await waiting.future;
    if (shouldFail) return false;
    return super.setBool(key, value);
  }
}

Widget _app(ThemeProvider theme, {double scale = 1}) =>
    ChangeNotifierProvider.value(
      value: theme,
      child: Builder(
        builder: (context) => GoldenTestApp(
          themeMode: context.watch<ThemeProvider>().themeMode,
          textScaler: TextScaler.linear(scale),
          home: const AppearanceSettingsScreen(),
        ),
      ),
    );

final _selector = find.byKey(const ValueKey('appearance-theme-mode'));

void _expectSelection(WidgetTester tester, ThemeMode mode) {
  expect(
    tester.widget<CampusSegmentedControl<ThemeMode>>(_selector).selectedValue,
    mode,
  );
  final selected = find.descendant(
    of: _selector,
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.selected == true,
    ),
  );
  expect(selected, findsOneWidget);
  expect(
    Theme.of(tester.element(_selector)).brightness,
    mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
  );
}

Future<void> _choose(WidgetTester tester, String label) async {
  final item = find.descendant(of: _selector, matching: find.text(label));
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  tearDown(() => AppPreferencesStore.setCustomInstance(null));

  testWidgets('三种模式均可直接切换，旧双开设置只选中跟随系统', (tester) async {
    AppPreferencesStore.setMockInitialValues({
      'night_mode': true,
      'night_mode_follow_system': true,
    });
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.loadThemeForTesting();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    _expectSelection(tester, ThemeMode.system);

    for (final (label, mode) in [
      ('深色模式', ThemeMode.dark),
      ('跟随系统', ThemeMode.system),
      ('浅色模式', ThemeMode.light),
      ('深色模式', ThemeMode.dark),
      ('浅色模式', ThemeMode.light),
      ('跟随系统', ThemeMode.system),
    ]) {
      await _choose(tester, label);
      _expectSelection(tester, mode);
      final restored = ThemeProvider();
      expect(restored.themeMode, mode);
      restored.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('跟随系统响应系统明暗变化，手动模式保持用户选择', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    for (final mode in ThemeMode.values) {
      await theme.setThemeMode(mode);
      for (final brightness in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(_selector)).brightness,
          mode == ThemeMode.system
              ? brightness
              : mode == ThemeMode.dark
                  ? Brightness.dark
                  : Brightness.light,
        );
        expect(
          tester
              .widget<CampusSegmentedControl<ThemeMode>>(_selector)
              .selectedValue,
          mode,
        );
      }
    }
  });

  testWidgets('配色模式支持键盘 Enter 与空格切换并更新选中语义', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    for (final (label, mode, key) in [
      ('浅色模式', ThemeMode.light, LogicalKeyboardKey.enter),
      ('深色模式', ThemeMode.dark, LogicalKeyboardKey.space),
    ]) {
      final item = find.descendant(of: _selector, matching: find.text(label));
      Focus.of(tester.element(item)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      _expectSelection(tester, mode);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败提示并可重试', (tester) async {
    final store = _FailingStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    await _choose(tester, '深色模式');
    expect(find.text('配色已切换，但未能保存，请重试'), findsOneWidget);
    store.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('配色已切换，但未能保存，请重试'), findsNothing);
    final restored = ThemeProvider();
    addTearDown(restored.dispose);
    expect(restored.themeMode, ThemeMode.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存期间离开页面不会弹出过期失败提示', (tester) async {
    final pending = Completer<void>();
    AppPreferencesStore.setCustomInstance(_FailingStore()..pending = pending);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    await _choose(tester, '深色模式');
    await tester.pumpWidget(const MaterialApp(home: Text('已离开设置')));
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('已离开设置'), findsOneWidget);
    expect(find.text('配色已切换，但未能保存，请重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速选回同一模式时旧保存失败不会覆盖新成功结果', (tester) async {
    final pending = Completer<void>();
    final store = _FailingStore()..pending = pending;
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    await _choose(tester, '深色模式');
    store.fail = false;
    await _choose(tester, '浅色模式');
    await _choose(tester, '深色模式');
    pending.complete();
    await tester.pumpAndSettle();
    _expectSelection(tester, ThemeMode.dark);
    expect(find.text('配色已切换，但未能保存，请重试'), findsNothing);
    final restored = ThemeProvider();
    addTearDown(restored.dispose);
    expect(restored.themeMode, ThemeMode.dark);
  });

  for (final (name, size, mode, scale) in [
    ('phone-light', const Size(360, 800), ThemeMode.light, 1.0),
    ('phone-dark', const Size(360, 800), ThemeMode.dark, 1.0),
    ('phone-large', const Size(360, 800), ThemeMode.light, 1.5),
    ('tablet-dark', const Size(1280, 800), ThemeMode.dark, 1.0),
  ]) {
    testWidgets('配色选择器 $name 实际渲染与选中语义', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setThemeMode(mode);
      const captureKey = ValueKey('appearance-theme-capture');
      await tester.pumpWidget(RepaintBoundary(
        key: captureKey,
        child: _app(theme, scale: scale),
      ));
      await tester.pumpAndSettle();
      _expectSelection(tester, mode);
      for (final label in ['跟随系统', '浅色模式', '深色模式']) {
        expect(find.text(label).hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);

      final directory = Platform.environment['APPEARANCE_QA_DIR'];
      if (directory != null) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File('$directory/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
