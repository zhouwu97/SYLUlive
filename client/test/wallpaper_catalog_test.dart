import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/config/wallpaper_catalog.dart';

void main() {
  test('竖屏内置壁纸只保留黄帽子和图一', () {
    expect(
      phonePresetWallpaperAssets,
      const ['morenbeijing.jpeg', 'wallpaper_custom_01.png'],
    );
  });

  test('横屏内置壁纸不重复默认背景', () {
    expect(
      landscapePresetWallpaperAssets,
      const [
        'tablet_default_landscape.png',
        'tablet_landscape_01.png',
        'tablet_landscape_02.png',
        'tablet_landscape_03.png',
        'tablet_landscape_04.png',
        'tablet_landscape_05.png',
        'tablet_landscape_06.png',
        'tablet_landscape_08.png',
      ],
    );
  });
}
