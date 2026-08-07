import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';

Widget _buildWrapper(ThemeProvider theme) {
  return ChangeNotifierProvider<ThemeProvider>.value(
    value: theme,
    child: const MaterialApp(
      home: Scaffold(
        body: GlobalBackgroundWrapper(child: SizedBox.shrink()),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  Future<ThemeProvider> _provider() async {
    final theme = ThemeProvider(loadOnStart: false);
    await theme.loadThemeForTesting();
    return theme;
  }

  testWidgets('简洁模式下不渲染任何模糊层', (tester) async {
    final theme = await _provider();
    await theme.setBackgroundBlur(12);
    // 简洁模式下即使保留了模糊数值也不渲染
    expect(theme.isCleanBackgroundMode, isTrue);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('自定义背景 fillScreen 模式产生统一模糊层', (tester) async {
    final theme = await _provider();
    // 横竖屏都配置，避免测试窗口方向触发兜底填充逻辑
    await theme.setBackgroundImage('portrait.jpg', fillScreen: true);
    await theme.setLandscapeBackgroundImage('landscape.jpg', fillScreen: true);
    await theme.setBackgroundBlur(12);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(theme.shouldShowCustomBackground, isTrue);
    // 填满模式：1 张 cover 图 + 1 个外层 ImageFiltered
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ImageFiltered),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
  });

  testWidgets('自定义背景 contain 模式整个组合层被统一模糊', (tester) async {
    final theme = await _provider();
    await theme.setBackgroundImage('portrait.jpg', fillScreen: false);
    await theme.setLandscapeBackgroundImage('landscape.jpg', fillScreen: false);
    await theme.setBackgroundBlur(12);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    // 外层只存在一个 ImageFiltered，同时包含 cover 补边图与 contain 主图
    expect(find.byType(ImageFiltered), findsOneWidget);
    final filtered = find.byType(ImageFiltered);
    expect(
      find.descendant(of: filtered, matching: find.byType(Image)),
      findsNWidgets(2),
    );
  });

  testWidgets('blur 为 0 时不创建 ImageFiltered', (tester) async {
    final theme = await _provider();
    await theme.setBackgroundImage('portrait.jpg', fillScreen: true);
    await theme.setLandscapeBackgroundImage('landscape.jpg', fillScreen: true);
    await theme.setBackgroundBlur(0);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(find.byType(ImageFiltered), findsNothing);
    // 背景图仍正常渲染
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('简洁模式下保存的模糊值不影响渲染，仅自定义模式生效', (tester) async {
    final theme = await _provider();
    // 保留模糊数值但切回简洁模式
    await theme.setBackgroundBlur(20);
    await theme.setCleanBackgroundMode();

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(theme.backgroundBlur, 20);
    expect(find.byType(ImageFiltered), findsNothing);
  });
}
