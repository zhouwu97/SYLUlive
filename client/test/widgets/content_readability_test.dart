import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/state_placeholder.dart';
import 'package:shenliyuan/widgets/canteen/canteen_empty_state.dart';
import 'package:shenliyuan/widgets/edu_grade/grade_empty_state.dart';
import 'package:shenliyuan/widgets/edu_grade/graduation_warning_empty_state.dart';
import 'package:shenliyuan/widgets/exam_papers/exam_paper_empty_state.dart';

import '../helpers/active_backdrop_filters.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Stripes extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 2) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 2, size.height),
          Paint()..color = (x ~/ 2).isEven ? Colors.white : Colors.black);
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final dark in [false, true]) {
    for (final large in [false, true]) {
      for (final kind in [
        'state',
        'grades',
        'grade-error',
        'papers',
        'canteen',
        'graduation'
      ]) {
        testWidgets('$kind dark=$dark large=$large 壁纸上的文字有底面且不移动',
            (tester) async {
          await setGoldenViewport(tester, GoldenViewports.phone390x844);
          final theme = ThemeProvider(loadOnStart: false);
          addTearDown(theme.dispose);
          var retries = 0;
          final (title, widget) = switch (kind) {
            'state' => (
                '暂无内容',
                StatePlaceholder(
                    title: '暂无内容',
                    subtitle: '稍后再试',
                    icon: Icons.inbox,
                    actionLabel: '重试',
                    onAction: () => retries++)
              ),
            'grades' => (
                '当前学期暂无成绩',
                const GradeEmptyState(state: GradePageState.empty)
              ),
            'grade-error' => (
                '成绩获取失败',
                GradeEmptyState(
                    state: GradePageState.error, onRetry: () => retries++)
              ),
            'papers' => (
                '还没有试卷',
                const ExamPaperEmptyState(
                    icon: Icons.description,
                    title: '还没有试卷',
                    message: '分享试卷帮助同学复习')
              ),
            'canteen' => (
                '暂无商家',
                CanteenEmptyState(
                    title: '暂无商家',
                    subtitle: '稍后再试',
                    actionLabel: '重试',
                    onAction: () => retries++)
              ),
            _ => ('功能验证中', const GraduationWarningEmptyState()),
          };
          await tester.pumpWidget(ChangeNotifierProvider.value(
            value: theme,
            child: GoldenTestApp(
                themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                textScaler: large
                    ? GoldenTextProfile.large.scaler
                    : TextScaler.noScaling,
                home: Scaffold(body: Center(child: widget))),
          ));
          await tester.pumpAndSettle();
          final before = tester.getRect(find.text(title));
          await theme.setBackgroundImage('morenbeijing.jpeg');
          await theme.setComponentOpacity(.75);
          for (final glass in [false, true, false]) {
            await theme.setFrostedGlass(glass);
            await tester.pumpAndSettle();
            expect(
                find.ancestor(
                    of: find.text(title),
                    matching: find.byType(AppContentSurface)),
                findsOneWidget);
            expect(tester.getRect(find.text(title)), before);
            expect(
                activeBackdropFilters(), glass ? findsOneWidget : findsNothing);
            final decoration = tester
                .widget<DecoratedBox>(find
                    .ancestor(
                        of: find.text(title),
                        matching: find.byType(DecoratedBox))
                    .first)
                .decoration as BoxDecoration;
            expect(decoration.color!.a, closeTo(.75, .005));
            final hint = switch (kind) {
              'state' || 'canteen' => find.text('稍后再试'),
              'grades' => find.text('本学期可能暂未录入成绩\n请稍后刷新或切换其他学期'),
              'grade-error' => find.text('教务登录可能已经过期'),
              'papers' => find.text('分享试卷帮助同学复习'),
              _ => find.textContaining('正在验证学校培养方案'),
            };
            final hintColor = tester.widget<Text>(hint).style!.color;
            expect(hintColor,
                Theme.of(tester.element(hint)).colorScheme.onSurfaceVariant);
            expect(hintColor!.a, 1, reason: '说明文字本身不能随着底面再次变淡');
            expect(tester.takeException(), isNull);
          }
          if (kind == 'state' || kind == 'grade-error' || kind == 'canteen') {
            await tester.tap(find.text(kind == 'grade-error' ? '重新加载' : '重试'));
            expect(retries, 1);
          }
        });
      }
    }
  }

  testWidgets('已有卡片内不重复叠加底色或模糊', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlass(true);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: const GoldenTestApp(
          home: Scaffold(
              body: AppCardMaterial(
                  child: AppContentSurface(
                      child: StatePlaceholder(
                          title: '暂无内容', icon: Icons.inbox))))),
    ));
    await tester.pumpAndSettle();
    expect(activeBackdropFilters(), findsOneWidget);
    for (final surface
        in tester.widgetList<AppCardSurface>(find.byType(AppCardSurface))) {
      expect(surface.surfaceOpacity, 0);
    }
    expect(tester.takeException(), isNull);
  });

  for (final reading in [false, true]) {
    for (final lazy in [false, true]) {
      testWidgets('底面真实模糊壁纸，前景不淡化 reading=$reading lazy=$lazy', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        await theme.setComponentOpacity(.55);
        final capture = GlobalKey();
        const text = SizedBox(height: 100, width: 220, child: Text('前景文字保持清晰'));
        final content = reading
            ? const AppContentSurface.reading(child: text)
            : const AppContentSurface(child: text);
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: GoldenTestApp(
              home: Scaffold(
                  body: RepaintBoundary(
            key: capture,
            child: Stack(fit: StackFit.expand, children: [
              CustomPaint(painter: _Stripes()),
              if (lazy)
                ListView.builder(itemCount: 10, itemBuilder: (_, i) => content)
              else
                Center(child: content),
            ]),
          ))),
        ));
        Future<int> spread({bool outside = false}) async {
          final bounds = tester.getRect(find.byType(AppContentSurface).first);
          return (await tester.runAsync(() async {
            final image = await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
            try {
              final data =
                  (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
              final values = [
                for (var x = outside
                        ? bounds.left.round() - 6
                        : bounds.left.round() + 25;
                    x <
                        (outside
                            ? bounds.left.round() - 2
                            : bounds.right.round() - 25);
                    x++)
                  data.getUint8(
                      ((bounds.top.round() + 70) * image.width + x) * 4 + 2)
              ];
              return values.reduce(math.max) - values.reduce(math.min);
            } finally {
              image.dispose();
            }
          }))!;
        }

        await tester.pumpAndSettle();
        expect(await spread(), greaterThan(80));
        await theme.setFrostedGlass(true);
        await tester.pumpAndSettle();
        expect(await spread(), lessThan(20),
            reason: '检查实际模糊后的像素，而非仅检查滤镜 Widget 是否存在');
        if (reading && !lazy) {
          expect(await spread(outside: true), lessThan(20),
              reason: '正文圆角底面应覆盖文字外侧的留白，不能只模糊文字原边界');
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
