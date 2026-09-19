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

  testWidgets('frostedGlass=false 时 GlassContainer 内不渲染 BackdropFilter', (tester) async {
    final theme = await _createProvider();
    expect(theme.frostedGlass, isFalse);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('Card Content'), findsOneWidget);
  });

  testWidgets('frostedGlass=true 时 GlassContainer 内渲染 BackdropFilter', (tester) async {
    final theme = await _createProvider();
    await theme.setFrostedGlass(true);
    expect(theme.frostedGlass, isTrue);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pump();

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('Card Content'), findsOneWidget);
  });

  testWidgets('底栏设为液态玻璃但 frostedGlass=false 时，GlassContainer 仍然无 BackdropFilter', (tester) async {
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
}
