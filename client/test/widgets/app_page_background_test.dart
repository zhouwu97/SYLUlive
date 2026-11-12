import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_page_background.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('切换背景不重建 Scaffold 状态、不清空表单和滚动位置', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    final input = TextEditingController();
    final scroll = ScrollController();
    addTearDown(theme.dispose);
    addTearDown(input.dispose);
    addTearDown(scroll.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
          home: AppPageBackground(
              builder: (context) => Scaffold(
                    key: scaffold,
                    backgroundColor:
                        AppPageBackground.color(context, Colors.white),
                    appBar: AppBar(title: const Text('测试内容页')),
                    body: ListView(controller: scroll, children: [
                      TextField(controller: input),
                      const SizedBox(height: 1200),
                    ]),
                  ))),
    ));
    await tester.pumpAndSettle();
    final state = scaffold.currentState;
    await tester.enterText(find.byType(TextField), '保留草稿');
    // 离开编辑状态再滚动，避免 EditableText 的保焦可见性请求主动滚回输入框。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    scroll.jumpTo(120);
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(find.byKey(scaffold)).backgroundColor,
        Colors.transparent);
    expect(find.byType(CustomBackgroundLayer), findsOneWidget);
    for (final glass in [true, false]) {
      await theme.setFrostedGlass(glass);
      await tester.pumpAndSettle();
      expect(scaffold.currentState, same(state));
      expect(input.text, '保留草稿');
      expect(scroll.offset, 120);
      expect(tester.widget<Scaffold>(find.byKey(scaffold)).backgroundColor,
          Colors.transparent);
      expect(tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
          isNull);
      final pageTheme = Theme.of(tester.element(find.byKey(scaffold)));
      expect(pageTheme.appBarTheme.backgroundColor, Colors.transparent);
      expect(find.byType(CustomBackgroundLayer), findsOneWidget);
    }
    await theme.setCleanBackgroundMode();
    await tester.pumpAndSettle();
    expect(scaffold.currentState, same(state));
    expect(input.text, '保留草稿');
    expect(scroll.offset, 120);
    expect(tester.widget<Scaffold>(find.byKey(scaffold)).backgroundColor,
        Colors.white);
    await theme.trySetCustomBackgroundMode();
    await tester.pumpAndSettle();
    expect(scaffold.currentState, same(state));
    expect(input.text, '保留草稿');
    expect(scroll.offset, 120);
    expect(tester.widget<Scaffold>(find.byKey(scaffold)).backgroundColor,
        Colors.transparent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无外观 Provider 的独立页面保持原有样式', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: AppPageBackground(
            builder: (_) => const Scaffold(
                  backgroundColor: Colors.blue,
                  body: Text('独立页面'),
                ))));
    expect(find.text('独立页面'), findsOneWidget);
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.blue);
    expect(find.byType(CustomBackgroundLayer), findsNothing);
  });

  testWidgets('共享背景同时覆盖普通二级页和直接绘制背景的分栏页面', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setBackgroundBlur(10);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
          home: GlobalBackgroundWrapper(
        child: SharedPageBackground(
            child: AppPageBackground(
          builder: (_) => const Stack(children: [
            Positioned.fill(child: CustomBackgroundLayer()),
            Center(child: Text('共享背景页面')),
          ]),
        )),
      )),
    ));
    await tester.pumpAndSettle();
    final scope = find.byType(SharedPageBackground);
    expect(find.text('共享背景页面'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(
        find.descendant(of: scope, matching: find.byType(Image)), findsNothing);
    await theme.setCleanBackgroundMode();
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('共享背景页面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
