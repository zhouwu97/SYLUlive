import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/glass_container.dart';

Widget _buildWrapper(ThemeProvider theme) {
  return ChangeNotifierProvider<ThemeProvider>.value(
    value: theme,
    child: const MaterialApp(
      home: Scaffold(
        body: GlassContainer(
          blur: 10,
          child: Text('Card Content'),
        ),
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

  testWidgets('frostedGlass=false 时 GlassContainer 内不渲染 BackdropFilter',
      (tester) async {
    final theme = await _createProvider();
    expect(theme.frostedGlass, isFalse);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('Card Content'), findsOneWidget);
  });

  testWidgets('frostedGlass=true 时 GlassContainer 内渲染 BackdropFilter',
      (tester) async {
    final theme = await _createProvider();
    await theme.setFrostedGlass(true);
    expect(theme.frostedGlass, isTrue);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('Card Content'), findsOneWidget);
  });

  testWidgets('运行时切换毛玻璃开关会同步更新已挂载组件', (tester) async {
    final theme = await _createProvider();

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);

    await theme.setFrostedGlass(true);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);

    await theme.setFrostedGlass(false);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets(
      '底栏设为液态玻璃但 frostedGlass=false 时，GlassContainer 仍然无 BackdropFilter',
      (tester) async {
    final theme = await _createProvider();
    await theme.setBottomNavStyle(BottomNavStyle.liquidGlass);
    expect(theme.liquidGlass, isTrue);
    expect(theme.frostedGlass, isFalse);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    // 核心解耦验证：底栏液态玻璃不再污染普通卡片
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('Card Content'), findsOneWidget);
  });

  testWidgets('自定义背景且 frostedGlass=false 时，GlassContainer 具备保底不透明度 (>= 0.85)',
      (tester) async {
    final theme = await _createProvider();
    await theme.setBackgroundImage('test_bg.jpg');
    expect(theme.isCustomBackgroundMode, isTrue);
    expect(theme.frostedGlass, isFalse);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    final containerFinder = find.byWidgetPredicate((widget) {
      if (widget is Container && widget.decoration is BoxDecoration) {
        final box = widget.decoration as BoxDecoration;
        return box.color != null && box.color!.a >= 0.85;
      }
      return false;
    });
    expect(containerFinder, findsWidgets);
  });
}
