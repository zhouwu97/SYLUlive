import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/providers/theme_provider.dart';

Future<ThemeProvider> _loadProvider(WidgetTester tester) async {
  final provider = ThemeProvider(loadOnStart: false);
  await provider.loadThemeForTesting();
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('无模式配置时默认简洁，旧背景配置会被保留但不显示', (tester) async {
    SharedPreferences.setMockInitialValues({
      'background_image': 'old_background.jpg',
      'background_fill_screen': true,
    });

    final provider = await _loadProvider(tester);

    expect(provider.backgroundMode, AppBackgroundMode.clean);
    expect(provider.backgroundImage, 'old_background.jpg');
    expect(provider.hasAnyBackground, isTrue);
    expect(provider.shouldShowCustomBackground, isFalse);
  });

  testWidgets('无背景时不能进入自定义模式', (tester) async {
    SharedPreferences.setMockInitialValues({});

    final provider = await _loadProvider(tester);
    final switched = await provider.trySetCustomBackgroundMode();

    expect(switched, isFalse);
    expect(provider.backgroundMode, AppBackgroundMode.clean);
    expect(provider.shouldShowCustomBackground, isFalse);
  });

  testWidgets('保存背景后自动进入自定义模式', (tester) async {
    SharedPreferences.setMockInitialValues({});

    final provider = await _loadProvider(tester);
    await provider.setBackgroundImage('phone_background.jpg', fillScreen: true);

    expect(provider.backgroundMode, AppBackgroundMode.custom);
    expect(provider.hasAnyBackground, isTrue);
    expect(provider.shouldShowCustomBackground, isTrue);
  });

  testWidgets('恢复简洁模式不删除已保存背景', (tester) async {
    SharedPreferences.setMockInitialValues({
      'background_mode': 'custom',
      'background_image': 'phone_background.jpg',
    });

    final provider = await _loadProvider(tester);
    await provider.setCleanBackgroundMode();

    expect(provider.backgroundMode, AppBackgroundMode.clean);
    expect(provider.backgroundImage, 'phone_background.jpg');
    expect(provider.hasAnyBackground, isTrue);
    expect(provider.shouldShowCustomBackground, isFalse);
  });

  testWidgets('清空背景会删除竖屏和横屏配置并强制回到简洁模式', (tester) async {
    SharedPreferences.setMockInitialValues({
      'background_mode': 'custom',
      'background_image': 'phone_background.jpg',
      'landscape_background_image': 'landscape_background.jpg',
      'background_fill_screen': true,
      'landscape_background_fill_screen': true,
    });

    final provider = await _loadProvider(tester);
    await provider.clearBackground();

    expect(provider.backgroundMode, AppBackgroundMode.clean);
    expect(provider.backgroundImage, isNull);
    expect(provider.landscapeBackgroundImage, isNull);
    expect(provider.backgroundFillScreen, isFalse);
    expect(provider.landscapeBackgroundFillScreen, isFalse);
    expect(provider.hasAnyBackground, isFalse);
    expect(provider.shouldShowCustomBackground, isFalse);
  });
}
