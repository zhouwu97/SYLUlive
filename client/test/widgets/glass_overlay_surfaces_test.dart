import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_choice_chip.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';
import 'package:shenliyuan/widgets/app_popup_menu.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/widgets/course/course_term_switch_sheet.dart';
import 'package:shenliyuan/widgets/course/course_semester_start_picker.dart';
import 'package:shenliyuan/models/course_term.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['BACKGROUND_QA_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  testWidgets('玻璃菜单保留原菜单的键盘选择行为', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setFrostedGlass(true);
    String? baseline;
    String? actual;
    const entries = <PopupMenuEntry<String>>[
      PopupMenuItem(value: 'one', child: Text('一')),
      PopupMenuItem(value: 'disabled', enabled: false, child: Text('禁用')),
      PopupMenuItem(value: 'two', child: Text('二')),
    ];
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: GoldenTestApp(
          home: Scaffold(
              body: Row(children: [
        PopupMenuButton<String>(
            tooltip: '原菜单',
            itemBuilder: (_) => entries,
            onSelected: (value) => baseline = value),
        AppPopupMenuButton<String>(
            tooltip: '玻璃菜单',
            itemBuilder: (_) => entries,
            onSelected: (value) => actual = value),
      ]))),
    ));
    for (final tooltip in ['原菜单', '玻璃菜单']) {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }
    expect(baseline, isNotNull);
    expect(actual, baseline);
    expect(tester.takeException(), isNull);
  });
  for (final profile in ['light', 'dark', 'large']) {
    testWidgets('$profile 弹窗、菜单与芯片真实渲染及关闭回退', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setFrostedGlass(true);
      final capture = GlobalKey();
      var selected = false;
      String? menuResult;
      DateTime? pickedMonday;
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: RepaintBoundary(
            key: capture,
            child: GoldenTestApp(
              themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
              textScaler: profile == 'large'
                  ? GoldenTextProfile.large.scaler
                  : TextScaler.noScaling,
              home: GlobalBackgroundWrapper(
                  child: Scaffold(
                backgroundColor: Colors.transparent,
                body: StatefulBuilder(
                    builder: (context, setState) => Column(children: [
                          AppChoiceChip(
                              label: const Text('筛选'),
                              selected: selected,
                              onSelected: (value) =>
                                  setState(() => selected = value)),
                          AppPopupMenuButton<String>(
                              tooltip: '测试菜单',
                              icon: const Icon(Icons.more_horiz),
                              onSelected: (value) => menuResult = value,
                              itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'one', child: Text('可用项')),
                                    PopupMenuDivider(),
                                    PopupMenuItem(
                                        value: 'disabled',
                                        enabled: false,
                                        child: Text('禁用项')),
                                    PopupMenuItem(
                                        value: 'two', child: Text('第二项')),
                                  ]),
                          TextButton(
                              onPressed: () => showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AppAlertDialog(
                                          title: const Text('检查更新'),
                                          content: const TextField(
                                              decoration: InputDecoration(
                                                  labelText: '输入验证')),
                                          actions: [
                                            TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx),
                                                child: const Text('关闭'))
                                          ])),
                              child: const Text('打开弹窗')),
                          TextButton(
                              onPressed: () => CourseTermSwitchSheet.show(
                                  context,
                                  currentTerm: const CourseTerm(
                                      id: '2026-2027-3',
                                      title: '2026-2027 第一学期',
                                      year: '2026-2027',
                                      semester: 3),
                                  enrollmentYear: 2025),
                              child: const Text('学期弹层')),
                          TextButton(
                              onPressed: () async {
                                pickedMonday =
                                    await CourseSemesterStartPicker.show(
                                  context,
                                  term: const CourseTerm(
                                      id: '2026-2027-3',
                                      title: '2026-2027 第一学期',
                                      year: '2026-2027',
                                      semester: 3),
                                  initialMonday: DateTime(2026, 8, 24),
                                );
                              },
                              child: const Text('实际开学日期选择器')),
                        ])),
              )),
            )),
      ));
      await tester.pumpAndSettle();
      final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
      await tester
          .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      expect(selected, isTrue);
      await tester.tap(find.byTooltip('测试菜单'));
      await tester.pumpAndSettle();
      expect(find.text('禁用项'), findsOneWidget);
      expect(find.byType(PopupMenuDivider), findsNothing);
      final menu = find.ancestor(
          of: find.text('可用项'), matching: find.byType(AppCardMaterial));
      expect(menu, findsOneWidget);
      expect(find.descendant(of: menu, matching: find.byType(BackdropFilter)),
          findsOneWidget);
      await _capture(tester, capture, 'menu-$profile');
      await tester.tap(find.text('禁用项'));
      await tester.pumpAndSettle();
      expect(menuResult, isNull);
      expect(find.text('可用项'), findsOneWidget);
      await tester.tap(find.text('第二项'));
      await tester.pumpAndSettle();
      expect(menuResult, 'two');
      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AppDialog);
      expect(dialog, findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.byType(BackdropFilter)),
          findsOneWidget);
      final filter =
          find.descendant(of: dialog, matching: find.byType(BackdropFilter));
      expect(tester.getSize(filter).width, lessThan(390));
      expect(tester.getSize(filter).height, lessThan(500),
          reason: '模糊只能覆盖弹窗，不能铺满路由');
      await tester.enterText(find.byType(TextField), '测试输入');
      await _capture(tester, capture, 'dialog-$profile');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('学期弹层'));
      await tester.pumpAndSettle();
      expect(find.text('切换学期'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(CourseTermSwitchSheet),
              matching: find.byType(BackdropFilter)),
          findsOneWidget);
      await _capture(tester, capture, 'term-$profile');
      Navigator.pop(tester.element(find.text('切换学期')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('实际开学日期选择器'));
      await tester.pumpAndSettle();
      expect(find.text('设置开学第一周'), findsOneWidget);
      final calendarSurface = find.ancestor(
          of: find.text('设置开学第一周'), matching: find.byType(AppCardSurface));
      expect(calendarSurface, findsOneWidget);
      expect(
          find.descendant(
              of: calendarSurface, matching: find.byType(BackdropFilter)),
          findsOneWidget,
          reason: '实际日期选择器由一层玻璃承载，底部操作区不再叠加实色底板');
      await _capture(tester, capture, 'calendar-$profile');
      await theme.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(pickedMonday, DateTime(2026, 8, 24));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
