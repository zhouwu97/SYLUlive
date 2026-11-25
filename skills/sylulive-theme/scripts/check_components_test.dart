import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/theme_pack/theme_appearance.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_workshop_samples.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ThemeAppearance appearance;
  setUpAll(() async {
    const package = String.fromEnvironment('THEME_PACKAGE');
    if (package.isEmpty) fail('请用 THEME_PACKAGE 指定要检验的成品包');
    final pubspec = await File('pubspec.yaml').readAsString();
    final version = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)',
      multiLine: true,
    ).firstMatch(pubspec)![1]!;
    final pack = await ThemePackCodec.readFile(package, appVersion: version);
    final directory = await Directory.systemTemp.createTemp(
      'theme-components-',
    );
    addTearDown(() => directory.delete(recursive: true));
    for (final entry in pack.contents.entries) {
      final file = File('${directory.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value);
    }
    appearance = const ThemeAppearance.empty().apply(
      pack.manifest,
      pack.manifest.groups,
      directory.path,
    );
  });

  for (final brightness in Brightness.values) {
    for (final page in WorkshopSamplePage.values) {
      testWidgets('${brightness.name} · ${page.label} · 工坊组件状态', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        for (final state in WorkshopSampleState.values) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ThemeWorkshopSampleStage(
                  appearance: appearance,
                  brightness: brightness,
                  assetResolver: (path) => FileImage(File(path)),
                  page: page,
                  sampleState: state,
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('${page.label} · ${state.label}'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: state.label);
        }
      });
    }
  }

  testWidgets('课表与考试桌面小部件的工坊预览', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ThemeWorkshopWidgetPreviewPanel(appearance: appearance),
          ),
        ),
      ),
    );
    expect(find.text('浅色桌面小部件预览'), findsOneWidget);
    expect(find.text('深色桌面小部件预览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
