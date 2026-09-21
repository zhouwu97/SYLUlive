import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/toolbox_screen.dart';

Widget _buildWrapper(ThemeProvider theme) {
  return ChangeNotifierProvider<ThemeProvider>.value(
    value: theme,
    child: const MaterialApp(home: ToolboxScreen()),
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

  testWidgets('毛玻璃关闭时 Toolbox 卡片内不包含 BackdropFilter', (tester) async {
    final theme = await _createProvider();
    expect(theme.frostedGlass, isFalse);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pumpAndSettle();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('二课分查询'), findsOneWidget);
    expect(find.text('更多工具'), findsOneWidget);
  });

  testWidgets('毛玻璃开启时 Toolbox 卡片包含 BackdropFilter', (tester) async {
    final theme = await _createProvider();
    await theme.setFrostedGlass(true);
    expect(theme.frostedGlass, isTrue);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pumpAndSettle();

    expect(find.byType(BackdropFilter), findsWidgets);
    expect(find.text('二课分查询'), findsOneWidget);
    expect(find.text('更多工具'), findsOneWidget);
  });
}
