import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/startup_destination.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('预热存储后构造 Provider 立即应用持久化主题', () async {
    AppPreferencesStore.setMockInitialValues({
      'background_mode': 'custom',
      'background_image': 'my_wallpaper.jpg',
      'background_blur': 22.0,
      'background_transparency': 0.45,
      'night_mode': true,
      'bottom_nav_style': 'liquid_glass',
      'market_is_list_view': true,
    });
    await AppPreferencesStore.getInstance();

    final provider = ThemeProvider();

    expect(provider.isLoaded, isTrue);
    expect(provider.backgroundMode, AppBackgroundMode.custom);
    expect(provider.backgroundImage, 'my_wallpaper.jpg');
    expect(provider.backgroundBlur, 22.0);
    expect(provider.componentOpacity, 0.45);
    expect(provider.isDarkMode, isTrue);
    expect(provider.bottomNavStyle, BottomNavStyle.liquidGlass);
    expect(provider.marketIsListView, isTrue);
  });

  test('同步加载路径执行旧启动模式迁移', () async {
    AppPreferencesStore.setMockInitialValues({'start_on_timetable': true});
    await AppPreferencesStore.getInstance();

    final provider = ThemeProvider();

    expect(provider.isLoaded, isTrue);
    expect(provider.startupDestination, StartupDestinationMode.timetable);
  });

  test('新用户默认关闭预测性返回和毛玻璃，背景模糊为 0', () async {
    AppPreferencesStore.setMockInitialValues({});
    await AppPreferencesStore.getInstance();

    final provider = ThemeProvider();

    expect(provider.predictiveBack, isFalse);
    expect(provider.frostedGlass, isFalse);
    expect(provider.backgroundBlur, 0);
    expect(provider.liquidGlass, isFalse);
  });

  test('显式保存的预测性返回和毛玻璃设置不会被默认值覆盖', () async {
    AppPreferencesStore.setMockInitialValues({
      'predictive_back_enabled': true,
      'frosted_glass_enabled': true,
      'background_blur': 16.0,
    });

    await AppPreferencesStore.getInstance();
    final provider = ThemeProvider();

    expect(provider.predictiveBack, isTrue);
    expect(provider.frostedGlass, isTrue);
    expect(provider.backgroundBlur, 16);
  });
}
