import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/auth_expired_overlay.dart';

Widget _buildWrapper(
  ThemeProvider theme, {
  required VoidCallback onDismiss,
  required VoidCallback onRelogin,
}) {
  return ChangeNotifierProvider<ThemeProvider>.value(
    value: theme,
    child: MaterialApp(
      home: Scaffold(
        body: AuthExpiredOverlay(
          onDismiss: onDismiss,
          onRelogin: onRelogin,
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

  testWidgets('frostedGlass=false 时 AuthExpiredOverlay 无 BackdropFilter 且操作功能完整', (tester) async {
    final theme = await _createProvider();
    expect(theme.frostedGlass, isFalse);

    var dismissed = false;

    await tester.pumpWidget(
      _buildWrapper(
        theme,
        onDismiss: () => dismissed = true,
        onRelogin: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('登录已过期'), findsOneWidget);
    expect(find.text('请重新登录以继续使用'), findsOneWidget);
    expect(find.text('暂时不管'), findsOneWidget);
    expect(find.text('重新登录'), findsOneWidget);

    await tester.tap(find.text('暂时不管'));
    await tester.pumpAndSettle();
    expect(dismissed, isTrue);
  });

  testWidgets('frostedGlass=true 时 AuthExpiredOverlay 包含 BackdropFilter 且操作功能完整', (tester) async {
    final theme = await _createProvider();
    await theme.setFrostedGlass(true);
    expect(theme.frostedGlass, isTrue);

    var relogined = false;

    await tester.pumpWidget(
      _buildWrapper(
        theme,
        onDismiss: () {},
        onRelogin: () => relogined = true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('登录已过期'), findsOneWidget);
    expect(find.text('重新登录'), findsOneWidget);

    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(relogined, isTrue);
  });
}
