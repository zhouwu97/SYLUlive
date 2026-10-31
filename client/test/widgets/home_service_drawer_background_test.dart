import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/widgets/home_service_drawer.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Future<List<int>> _capture(
    WidgetTester tester, GlobalKey key, String name) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData())!;
      final pixels = <int>[];
      // 卡片外的空白必须与整屏壁纸同位置一致，而非仅断言 Image 存在。
      for (final y in [400, 700]) {
        final offset = (y * image.width + 4) * 4;
        pixels.addAll(bytes.buffer.asUint8List(offset, 4));
      }
      final directory = Platform.environment['BACKGROUND_QA_DIR'];
      if (directory != null) {
        await Directory(directory).create(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$directory/$name.png')
            .writeAsBytes(png.buffer.asUint8List());
      }
      return pixels;
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in ['light', 'dark', 'large-text']) {
    testWidgets('侧栏 $profile 关闭毛玻璃仍绘制整屏壁纸，切换和重试保留状态', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      final capture = GlobalKey();
      var reference = true;
      var loading = false;
      var error = false;
      var retries = 0;
      var toolboxTaps = 0;
      late StateSetter update;

      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: GoldenTestApp(
          themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
          textScaler: profile == 'large-text'
              ? GoldenTextProfile.large.scaler
              : TextScaler.noScaling,
          home: Scaffold(
              body: RepaintBoundary(
            key: capture,
            child: StatefulBuilder(builder: (context, setState) {
              update = setState;
              if (reference) return const CustomBackgroundLayer();
              return Align(
                  alignment: Alignment.centerLeft,
                  child: HomeServiceDrawer(
                    checkedIn: false,
                    streakDays: 0,
                    checkInLoading: loading,
                    checkInError: error,
                    showCheckInDot: false,
                    waterSectionsLoading: loading,
                    announcements: const [],
                    unreadAnnouncements: const [],
                    onCheckIn: () {},
                    onRetryCheckIn: () => retries++,
                    onOpenToolbox: () => toolboxTaps++,
                    onOpenAnnouncements: () {},
                    onOpenCompetitions: () {},
                    onOpenGrades: () {},
                    onOpenExamSchedule: () {},
                    onOpenFeedback: () {},
                    onOpenWaterSectionDirectory: () {},
                  ));
            }),
          )),
        ),
      ));
      await tester.pumpAndSettle();
      final wallpaper = tester.widget<Image>(find.byType(Image)).image;
      await tester
          .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
      await tester.pumpAndSettle();
      final expected =
          await _capture(tester, capture, 'drawer-$profile-reference');
      update(() => reference = false);
      await tester.pumpAndSettle();
      final actual = await _capture(tester, capture, 'drawer-$profile-off');
      expect(actual, expected, reason: '关闭模糊不应恢复覆盖壁纸的底板');
      expect(find.byType(CustomBackgroundLayer), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('暂无公告'), findsOneWidget);

      await theme.setFrostedGlass(true);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNWidgets(5));
      await theme.setFrostedGlass(false);
      update(() => loading = true);
      await tester.pump();
      expect(find.text('加载中'), findsOneWidget);
      expect(
          await _capture(tester, capture, 'drawer-$profile-loading'), expected);
      // 模拟异步签到请求失败，版块回退本地目录，重试仍可操作。
      update(() {
        loading = false;
        error = true;
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('签到重试'));
      await tester.tap(find.text('工具箱'));
      expect(retries, 1);
      expect(toolboxTaps, 1);
      expect(find.text('新生求助'), findsOneWidget);
      expect(
          await _capture(tester, capture, 'drawer-$profile-retry'), expected);

      await theme.setCleanBackgroundMode();
      await tester.pumpAndSettle();
      expect(find.byType(CustomBackgroundLayer), findsNothing);
      expect(theme.backgroundImage, 'morenbeijing.jpeg');
      await theme.trySetCustomBackgroundMode();
      await tester.pumpAndSettle();
      expect(await _capture(tester, capture, 'drawer-$profile-restored'),
          expected);
      expect(tester.takeException(), isNull);
    });
  }
}
