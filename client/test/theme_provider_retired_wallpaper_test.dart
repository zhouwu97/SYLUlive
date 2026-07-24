import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('已删除的内置竖屏壁纸迁移为黄帽子原图', () async {
    AppPreferencesStore.setMockInitialValues({
      'background_mode': 'custom',
      'background_image': r'C:\app\documents\remote_phone_wallpaper_03.png',
      'background_fill_screen': true,
    });

    final provider = ThemeProvider(loadOnStart: false);
    await provider.loadThemeForTesting();

    expect(provider.backgroundImage, 'morenbeijing.jpeg');
    expect(provider.backgroundFillScreen, isFalse);
    expect(provider.backgroundMode, AppBackgroundMode.custom);

    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getString('background_image'), 'morenbeijing.jpeg');
    expect(prefs.getBool('background_fill_screen'), isFalse);
  });

  test('用户自定义背景保持不变', () async {
    AppPreferencesStore.setMockInitialValues({
      'background_mode': 'custom',
      'background_image': r'C:\app\documents\my_wallpaper.png',
      'background_fill_screen': true,
    });

    final provider = ThemeProvider(loadOnStart: false);
    await provider.loadThemeForTesting();

    expect(provider.backgroundImage, r'C:\app\documents\my_wallpaper.png');
    expect(provider.backgroundFillScreen, isTrue);
  });
}
