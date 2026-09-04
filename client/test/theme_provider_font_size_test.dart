import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_text_scaler.dart';

Future<ThemeProvider> _loadProvider() async {
  final provider = ThemeProvider(loadOnStart: false);
  await provider.loadThemeForTesting();
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未保存字体档位时使用标准大小', () async {
    AppPreferencesStore.setMockInitialValues({});

    final provider = await _loadProvider();

    expect(provider.fontSizePreset, AppFontSizePreset.standard);
  });

  test('启动时恢复已保存的字体档位', () async {
    AppPreferencesStore.setMockInitialValues({
      'font_size_preset': 'extra_large',
    });

    final provider = await _loadProvider();

    expect(provider.fontSizePreset, AppFontSizePreset.extraLarge);
  });

  test('启动时恢复新增的两个中间字体档位', () async {
    AppPreferencesStore.setMockInitialValues({
      'font_size_preset': 'slightly_small',
    });
    final slightlySmall = await _loadProvider();
    expect(slightlySmall.fontSizePreset, AppFontSizePreset.slightlySmall);

    AppPreferencesStore.setMockInitialValues({
      'font_size_preset': 'large_plus',
    });
    final largePlus = await _loadProvider();
    expect(largePlus.fontSizePreset, AppFontSizePreset.largePlus);
  });

  test('未知字体档位回退到标准大小', () async {
    AppPreferencesStore.setMockInitialValues({
      'font_size_preset': 'broken_value',
    });

    final provider = await _loadProvider();

    expect(provider.fontSizePreset, AppFontSizePreset.standard);
  });

  test('切换字体档位后持久化并且重复设置不再次通知', () async {
    AppPreferencesStore.setMockInitialValues({});
    final provider = await _loadProvider();
    var notificationCount = 0;
    provider.addListener(() => notificationCount++);

    await provider.setFontSizePreset(AppFontSizePreset.large);

    expect(provider.fontSizePreset, AppFontSizePreset.large);
    expect(notificationCount, 1);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getString('font_size_preset'), 'large');

    await provider.setFontSizePreset(AppFontSizePreset.large);
    expect(notificationCount, 1);
  });
}
