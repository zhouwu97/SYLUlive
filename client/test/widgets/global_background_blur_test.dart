import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

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

Future<ThemeProvider> _createProvider() async {
  final theme = ThemeProvider(loadOnStart: false);
  await theme.loadThemeForTesting();
  return theme;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  testWidgets('简洁模式下不渲染任何模糊层', (tester) async {
    final theme = await _createProvider();
    await theme.setBackgroundBlur(12);
    // 简洁模式下即使保留了模糊数值也不渲染
    expect(theme.isCleanBackgroundMode, isTrue);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('自定义背景 fillScreen 模式产生统一模糊层', (tester) async {
    final theme = await _createProvider();
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
    final theme = await _createProvider();
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
    final theme = await _createProvider();
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
    final theme = await _createProvider();
    // 保留模糊数值但切回简洁模式
    await theme.setBackgroundBlur(20);
    await theme.setCleanBackgroundMode();

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(theme.backgroundBlur, 20);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('自定义背景首次启用时默认没有高斯模糊', (tester) async {
    final theme = await _createProvider();

    expect(theme.backgroundBlur, 0);

    await theme.setBackgroundImage('portrait.jpg', fillScreen: true);
    await theme.setLandscapeBackgroundImage('landscape.jpg', fillScreen: true);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(find.byType(ImageFiltered), findsNothing);
  });

  test('背景解码尺寸在横竖屏与 cover/contain 下保持原图比例', () {
    final cover = AspectPreservingResizeImage.calculateTargetSize(
      intrinsicWidth: 4000,
      intrinsicHeight: 3000,
      targetWidth: 1080,
      targetHeight: 2400,
      fit: BoxFit.cover,
      maxDimension: 2560,
    );
    final contain = AspectPreservingResizeImage.calculateTargetSize(
      intrinsicWidth: 3000,
      intrinsicHeight: 4000,
      targetWidth: 2400,
      targetHeight: 1080,
      fit: BoxFit.contain,
      maxDimension: 2560,
    );

    expect(cover.width! / cover.height!, closeTo(4 / 3, 0.01));
    expect(cover.height!, greaterThanOrEqualTo(2400));
    expect(contain.width! / contain.height!, closeTo(3 / 4, 0.01));
    expect(contain.width!, lessThanOrEqualTo(2400));
    expect(contain.height!, lessThanOrEqualTo(1080));
  });

  test('极端宽高比的 cover 仍服从解码像素预算', () {
    final target = AspectPreservingResizeImage.calculateTargetSize(
      intrinsicWidth: 20000,
      intrinsicHeight: 2000,
      targetWidth: 1080,
      targetHeight: 2400,
      fit: BoxFit.cover,
      maxDimension: 2560,
      maxDecodedPixels: 1000000,
    );

    expect(target.width! * target.height!, lessThanOrEqualTo(1000000));
    expect(target.width! / target.height!, closeTo(10, 0.01));
  });
}
