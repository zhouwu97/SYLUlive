import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/startup_destination.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('存储预热后构造 Provider 立即为持久化主题（同步加载，无首帧跳变）', () async {
    AppPreferencesStore.setMockInitialValues({
      'background_mode': 'custom',
      'background_image': 'my_wallpaper.jpg',
      'background_blur': 22.0,
      'background_transparency': 0.45,
      'night_mode': true,
      'bottom_nav_style': 'liquid_glass',
      'market_is_list_view': true,
    });
    // 模拟 app_bootstrap 在 runApp 前的预热。
    await AppPreferencesStore.getInstance();

    // 不 pump 帧：isLoaded 必须在构造完成后同步为 true，
    // 否则首帧会用默认值渲染，加载完成后整体跳变。
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

  test('同步加载路径同样执行旧启动模式的一次性迁移', () async {
    AppPreferencesStore.setMockInitialValues({
      'start_on_timetable': true,
    });
    await AppPreferencesStore.getInstance();

    final provider = ThemeProvider();

    expect(provider.isLoaded, isTrue);
    expect(provider.startupDestination, StartupDestinationMode.timetable);
  });

  test('预热存储为空配置时同步应用默认主题', () async {
    AppPreferencesStore.setMockInitialValues({});
    await AppPreferencesStore.getInstance();

    final provider = ThemeProvider();

    expect(provider.isLoaded, isTrue);
    expect(provider.backgroundMode, AppBackgroundMode.clean);
    expect(provider.backgroundBlur, 10);
    expect(provider.componentOpacity, 0.7);
    expect(provider.isDarkMode, isFalse);
  });
}
