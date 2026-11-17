import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/theme_pack/theme_contrast.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_store.dart';
import 'package:shenliyuan/features/theme_pack/theme_resolver.dart';
import 'package:shenliyuan/features/theme_pack/theme_workshop_samples.dart';
import 'package:shenliyuan/features/theme_pack/theme_workshop_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_theme_tokens.dart';
import 'package:shenliyuan/widgets/post_card.dart';

import '../helpers/emoji_flow_qa.dart' show settleEmojiQAImages;
import '../helpers/load_test_fonts.dart';
import 'theme_pack_test.dart' show themeImage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });

  late Directory temp;
  late ThemePackStore store;
  late ThemeProvider provider;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sltheme-workshop-');
    store =
        ThemePackStore(directory: Directory(path.join(temp.path, 'themes')));
    AppPreferencesStore.setCustomInstance(MemoryPreferencesStore());
    provider = ThemeProvider(loadOnStart: false, themePackStore: store);
    await provider.loadThemeForTesting();
  });

  tearDown(() async {
    provider.dispose();
    AppPreferencesStore.setCustomInstance(null);
    await temp.delete(recursive: true);
  });

  test('工坊推导：#2F7FD8 常量角色映射、覆盖优先、8 色课表对比度与色相不变自动修正', () {
    const seed = Color(0xFF2F7FD8);
    final derived = ThemeResolver.deriveTokens(
      seedColor: seed,
      brightness: Brightness.light,
    );
    expect(derived['primary'], '#3C6090');
    expect(derived['background'], '#F9F9FF');
    expect(derived['card'], '#FFFFFF');
    expect(derived['textPrimary'], '#191C20');
    expect(derived['navSelected'], '#3C6090');

    // 存在覆盖值时覆盖优先
    final withOverride = ThemeResolver.deriveTokens(
      seedColor: seed,
      brightness: Brightness.light,
      overrides: const {'background': '#F5F9FF', 'card': '#FAFCFF'},
    );
    expect(withOverride['background'], '#F5F9FF');
    expect(withOverride['card'], '#FAFCFF');
    expect(withOverride['primary'], '#3C6090');

    // 亮暗两套自动生成的 8 色课程色板全部达到 4.5
    for (final brightness in Brightness.values) {
      final tokens = ThemeResolver.deriveTokens(
        seedColor: seed,
        brightness: brightness,
      );
      final bg = ThemeContrast.parseColor(tokens['background']!);
      final courseText = ThemeContrast.parseColor(tokens['courseCardText']!);
      final courses = ThemeResolver.generateCoursePalette(
        seedColor: seed,
        brightness: brightness,
        background: bg,
        courseCardText: courseText,
      );
      expect(courses.length, 8);
      for (final hex in courses) {
        final composed = Color.alphaBlend(
          ThemeContrast.parseColor(hex).withValues(alpha: 0.45),
          bg,
        );
        expect(ThemeContrast.ratio(courseText, composed), greaterThanOrEqualTo(4.5));
      }
    }

    // 自动修正低对比前景：达到 4.5 阈值且保持 HCT 色相不变
    const lowContrastBlue = Color(0xFF6FA8DC);
    final origHct = Hct.fromInt(lowContrastBlue.toARGB32());
    expect(ThemeContrast.ratio(lowContrastBlue, Colors.white), lessThan(4.5));
    final fixed = ThemeResolver.autoFixColorForContrast(
      foreground: lowContrastBlue,
      background: Colors.white,
      threshold: 4.5,
    );
    final fixedHct = Hct.fromInt(fixed.toARGB32());
    expect(ThemeContrast.ratio(fixed, Colors.white), greaterThanOrEqualTo(4.5));
    var hueDiff = (fixedHct.hue - origHct.hue).abs();
    if (hueDiff > 180) hueDiff = 360 - hueDiff;
    expect(hueDiff, lessThan(2.0));
  });

  test('规范包导出与草稿持久化：1080×2340 预览、超 2560 壁纸缩小且原图不烘焙 adjustments、对比度门禁', () async {
    final draftStore = ThemeWorkshopDraftStore(
      themesDirectory: Directory(path.join(temp.path, 'themes')),
    );
    final state = ThemeWorkshopStateData.fromDefault(seedHex: '#2F7FD8');
    state.name = '海盐蓝工坊测试';
    state.author = '工坊作者';

    // 写入一张 3000×1500 纯色大图（RGB 100, 150, 200），附带非中性 adjustments
    final largeWallPath = path.join(temp.path, 'large_wall.png');
    final largeImg = img.Image(width: 3000, height: 1500);
    img.fill(largeImg, color: img.ColorRgb8(100, 150, 200));
    await File(largeWallPath).writeAsBytes(img.encodePng(largeImg));

    state.light.wallpapers['global'] = {
      'portrait': largeWallPath,
      'fit': 'cover',
      'focalX': 0.5,
      'focalY': 0.5,
      'blur': 0.0,
      'scrim': 0.1,
      'adjustments': {
        'brightness': 40.0,
        'contrast': 150.0,
        'saturation': 60.0,
      },
    };
    state.layout['home'] = {
      'preset': 'immersive',
      'alignment': 'center',
      'imageHeight': 168.0,
      'imageWidth': 0.9,
    };
    state.light.cardStyle = {'borderWidth': 1.5, 'shadow': 'soft'};

    // 草稿保存并重新读取，全部内容一致
    await draftStore.save(state.draftId, state.toDraftJson());
    final loadedJson = await draftStore.load(state.draftId);
    expect(loadedJson, isNotNull);
    final restored = ThemeWorkshopStateData.fromDraftJson(loadedJson!);
    expect(restored.name, '海盐蓝工坊测试');
    expect(restored.layout['home']!['preset'], 'immersive');
    expect(restored.light.cardStyle, {'borderWidth': 1.5, 'shadow': 'soft'});
    expect(
      restored.light.wallpapers['global']!['adjustments']['brightness'],
      40.0,
    );

    // 正常导出：能被 codec 解析，预览图 1080×2340，壁纸长边缩小到 2560 且像素未烘焙 brightness +40
    final exportedBytes = await restored.exportPack(appVersion: '1.7.12');
    final decoded = await ThemePackCodec.decode(
      exportedBytes,
      appVersion: '9.0.0',
    );
    expect(decoded.manifest.name, '海盐蓝工坊测试');
    final lightPreview = img.decodeImage(decoded.contents['preview/light.png']!)!;
    expect(lightPreview.width, 1080);
    expect(lightPreview.height, 2340);

    final wallKey =
        decoded.manifest.data['light']['wallpapers']['global']['portrait']
            as String;
    expect(wallKey.endsWith('.jpg'), isTrue);
    final exportedWall = img.decodeImage(decoded.contents[wallKey]!)!;
    expect(exportedWall.width, 2560);
    expect(exportedWall.height, 1280);
    // 原图 RGB 为 (100, 150, 200)；若误把 brightness +40 / contrast 150% 烘焙进去，R 会升至 ~195
    final samplePixel = exportedWall.getPixel(100, 100);
    expect(samplePixel.r.toInt(), closeTo(100, 6));
    expect(
      decoded.manifest.data['light']['wallpapers']['global']['adjustments'],
      {'brightness': 40.0, 'contrast': 150.0, 'saturation': 60.0},
    );

    // 破坏对比度后导出应被门禁拦截
    restored.light.overrides['textPrimary'] = '#EAEAEA';
    await expectLater(
      restored.exportPack(appVersion: '1.7.12'),
      throwsA(isA<ThemeWorkshopContrastException>()),
    );
  });

  testWidgets('工坊交互：360×800 1.5x 十个 Tab 无溢出、点选预览定位、复制后独立编辑、贴纸调层与重置、保存失败重试',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var shouldFailSave = false;
    final draftStore = ThemeWorkshopDraftStore(
      themesDirectory: Directory(path.join(temp.path, 'themes')),
      writeHook: (_, __) async {
        if (shouldFailSave) {
          throw const FileSystemException('disk full');
        }
      },
    );

    final stickerA = File(path.join(temp.path, 'sa.png'));
    final stickerB = File(path.join(temp.path, 'sb.png'));
    final wallFile = File(path.join(temp.path, 'wall.png'));
    await tester.runAsync(() async {
      await stickerA.writeAsBytes(themeImage(48, 48));
      await stickerB.writeAsBytes(themeImage(48, 48));
      await wallFile.writeAsBytes(themeImage(200, 300));
    });

    final initial = ThemeWorkshopStateData.fromDefault();
    initial.light.wallpapers['global'] = {
      'portrait': wallFile.path,
      'fit': 'cover',
      'focalX': 0.5,
      'focalY': 0.5,
      'blur': 2.0,
      'scrim': 0.1,
    };
    initial.light.decorations['home'] = {
      'stickers': [
        {
          'image': stickerA.path,
          'x': 0.25,
          'y': 0.35,
          'width': 0.2,
          'rotation': 15.0,
        },
        {
          'image': stickerB.path,
          'x': 0.75,
          'y': 0.65,
          'width': 0.22,
          'rotation': -20.0,
        },
      ],
    };

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.buildAppTheme(Brightness.light),
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: ThemeWorkshopScreen(
            initialState: initial,
            draftStore: draftStore,
            appVersion: '1.7.12',
          ),
        ),
      ),
    );
    await settleEmojiQAImages(
      tester,
      tester.element(find.byType(ThemeWorkshopScreen)),
      tester.widgetList<Image>(find.byType(Image)).map((i) => i.image),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 1. 修改种子色后，上半屏预览组件的主题主色立即跟随变化
    await tester.enterText(
      find.byKey(const ValueKey('workshop-seed-hex-input')),
      '#C9617E',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    final stageCtx = tester.element(find.byType(PostCard));
    expect(
      AppThemeTokens.of(stageCtx).primary,
      isNot(const Color(0xFF147C72)),
    );

    // 2. 在 360×800、1.5x 字号下依次访问全部 10 个 Tab，均无溢出
    for (final tab in WorkshopTab.values) {
      final chip = find.byKey(ValueKey('workshop-tab-${tab.name}'));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    // 3. 点选预览区页头信息卡与帖子卡片自动定位到“布局”与“材质”编辑区
    await tester.tap(find.byKey(const ValueKey('home-themed-header-info')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workshop-editor-layout')),
      findsOneWidget,
    );
    // 切换到“集市”样例并点选商品卡片，自动定位到“材质”编辑区
    await tester.tap(find.text('集市').first);
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getTopLeft(find.byType(ThemeWorkshopSampleStage)) +
          const Offset(80, 70),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workshop-editor-material')),
      findsOneWidget,
    );

    // 4. 切换到深色模式执行“复制浅色壁纸设置”，随后修改深色模糊值不影响浅色（一次性复制无隐藏联动）
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    final wallTab = find.byKey(const ValueKey('workshop-tab-wallpapers'));
    await tester.ensureVisible(wallTab);
    await tester.tap(wallTab);
    await tester.pumpAndSettle();
    final copyBtn = find.byKey(const ValueKey('workshop-copy-light-wallpapers'));
    await tester.ensureVisible(copyBtn);
    await tester.tap(copyBtn);
    await tester.pump();
    expect(initial.dark.wallpapers['global']!['blur'], 2.0);
    initial.dark.wallpapers['global']!['blur'] = 8.0;
    expect(initial.light.wallpapers['global']!['blur'], 2.0);

    // 5. 切回浅色“装饰”Tab：调整贴纸前后层次，重置贴纸 1 不影响贴纸 2
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    final decoTab = find.byKey(const ValueKey('workshop-tab-decoration'));
    await tester.ensureVisible(decoTab);
    await tester.tap(decoTab);
    await tester.pumpAndSettle();

    final upBtn = find.text('上移一层');
    await tester.ensureVisible(upBtn);
    await tester.pumpAndSettle();
    await tester.tap(upBtn);
    await tester.pump();
    final stickersAfterMove =
        initial.light.decorations['home']!['stickers'] as List;
    expect(stickersAfterMove[0]['image'], stickerB.path);
    expect(stickersAfterMove[1]['image'], stickerA.path);

    // 当前选中移动后的贴纸 2（原 stickerA），点“重置此贴纸”只重置它，贴纸 1（stickerB）保持原位
    final resetSingleBtn = find.text('重置此贴纸');
    await tester.ensureVisible(resetSingleBtn);
    await tester.pumpAndSettle();
    await tester.tap(resetSingleBtn);
    await tester.pump();
    final stickersAfterReset =
        initial.light.decorations['home']!['stickers'] as List;
    expect(stickersAfterReset[1]['x'], 0.5);
    expect(stickersAfterReset[1]['rotation'], 0.0);
    expect(stickersAfterReset[0]['x'], 0.75);
    expect(stickersAfterReset[0]['rotation'], -20.0);

    // 6. 模拟草稿保存失败：编辑内容保留、顶栏出现“未保存 · 重试”，恢复后点击重试成功落盘
    shouldFailSave = true;
    final colorsTab = find.byKey(const ValueKey('workshop-tab-colors'));
    await tester.ensureVisible(colorsTab);
    await tester.tap(colorsTab);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('workshop-seed-hex-input')),
      '#3E6B4F',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.pump(const Duration(milliseconds: 900));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
    expect(initial.light.seedColor, '#3E6B4F');
    expect(
      find.byKey(const ValueKey('workshop-draft-retry')),
      findsOneWidget,
    );

    shouldFailSave = false;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('workshop-draft-retry')));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workshop-draft-retry')), findsNothing);
    final savedOnDisk = await tester.runAsync(
      () => draftStore.load(initial.draftId),
    );
    expect((savedOnDisk!['light'] as Map)['seedColor'], '#3E6B4F');

    await tester.pumpWidget(const SizedBox());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
  });
}
