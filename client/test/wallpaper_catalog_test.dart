import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/settings_screen.dart';

void main() {
  test('竖屏内置壁纸只保留黄帽子和图一', () {
    expect(
      phonePresetWallpaperAssets,
      const ['morenbeijing.jpeg', 'wallpaper_custom_01.png'],
    );
  });
}
