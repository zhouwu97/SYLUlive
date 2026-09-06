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
}
