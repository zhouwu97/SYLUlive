import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/theme_pack/theme_contrast.dart';
import 'package:shenliyuan/features/theme_pack/theme_appearance.dart';
import 'package:shenliyuan/features/theme_pack/theme_workshop_samples.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_store.dart';
import 'package:shenliyuan/features/theme_pack/theme_resolver.dart';
import 'package:shenliyuan/features/theme_pack/theme_workshop_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_theme_tokens.dart';
import 'package:shenliyuan/widgets/post_card.dart';

import '../helpers/emoji_flow_qa.dart'
    show settleEmojiQAImages, waitForEmojiWork;
import '../helpers/load_test_fonts.dart';
import 'theme_pack_test.dart' show themeImage;

class _WorkshopPreferences extends MemoryPreferencesStore {
  bool failAppearanceWrite = false;

  @override
  Future<bool> setString(String key, String value) async {
    if (failAppearanceWrite && key == ThemeProvider.appearanceKey) return false;
    return super.setString(key, value);
  }
}

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
  late _WorkshopPreferences prefs;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sltheme-workshop-');
    store =
        ThemePackStore(directory: Directory(path.join(temp.path, 'themes')));
    prefs = _WorkshopPreferences();
    AppPreferencesStore.setCustomInstance(prefs);
    provider = ThemeProvider(loadOnStart: false, themePackStore: store);
    await provider.loadThemeForTesting();
  });

  tearDown(() async {
    provider.dispose();
    AppPreferencesStore.setCustomInstance(null);
    await temp.delete(recursive: true);
  });

  testWidgets('工坊预览显示主题的空态和失败插画，加载和权限仍保留状态图标', (tester) async {
    final imagePath = path.join(temp.path, 'state.png');
    await tester.runAsync(() => File(imagePath).writeAsBytes(themeImage(64, 64)));
    final appearance = ThemeAppearance({
      'decoration': {
        'light': {
          'illustrations': {'empty': imagePath, 'error': imagePath},
        },
      },
    });
    for (final state in [
      WorkshopSampleState.empty,
      WorkshopSampleState.error,
      WorkshopSampleState.loading,
      WorkshopSampleState.permission,
    ]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ThemeWorkshopSampleStage(
            appearance: appearance,
            brightness: Brightness.light,
            assetResolver: (file) => FileImage(File(file)),
            page: WorkshopSamplePage.market,
            sampleState: state,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('theme-state-art-empty')),
          state == WorkshopSampleState.empty ? findsOneWidget : findsNothing);
      expect(find.byKey(const ValueKey('theme-state-art-error')),
          state == WorkshopSampleState.error ? findsOneWidget : findsNothing);
      if (state == WorkshopSampleState.loading) {
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      }
      if (state == WorkshopSampleState.permission) {
        expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
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
        expect(ThemeContrast.ratio(courseText, composed),
            greaterThanOrEqualTo(4.5));
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

  test('规范包导出与草稿持久化：1080×2340 预览、超 2560 壁纸缩小且原图不烘焙 adjustments、对比度门禁',
      () async {
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
    expect(decoded.manifest.data['bottomNav']['style'], 'liquid_glass');
    final lightPreview =
        img.decodeImage(decoded.contents[decoded.manifest.data['preview']['light']]!)!;
    expect(lightPreview.width, 1080);
    expect(lightPreview.height, 2340);

    final wallKey = decoded.manifest.data['light']['wallpapers']['global']
        ['portrait'] as String;
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

    // 低对比度不再由自动门禁拦截，由人工审核把关
    restored.light.overrides['textPrimary'] = '#EAEAEA';
    final lowContrastBytes = await restored.exportPack(appVersion: '1.7.12');
    expect(lowContrastBytes, isNotEmpty);
  });

  test('复杂预览图自动压缩到 2MB，导出包可重新导入', () async {
    final canvas = img.Image(width: 1080, height: 2340);
    final random = Random(42);
    for (final pixel in canvas) {
      pixel
        ..r = random.nextInt(256)
        ..g = random.nextInt(256)
        ..b = random.nextInt(256);
    }
    final png = Uint8List.fromList(img.encodePng(canvas));
    expect(png.length, greaterThan(2 * 1024 * 1024));
    final bytes = await ThemeWorkshopStateData.fromDefault().exportPack(
      appVersion: '1.7.12',
      renderedLightPng: png,
      renderedDarkPng: png,
    );
    final pack = await ThemePackCodec.decode(bytes, appVersion: '9.0.0');
    for (final mode in ['light', 'dark']) {
      final preview = pack.contents[pack.manifest.data['preview'][mode]]!;
      expect(preview.length, lessThanOrEqualTo(2 * 1024 * 1024));
      final decoded = img.decodeImage(preview)!;
      expect(decoded.width, 1080);
      expect(decoded.height, 2340);
    }
  });

  testWidgets('主题设置：360×800 1.5x 分类与全屏预览无溢出、点选预览定位、复制后独立编辑、贴纸调层与重置、保存失败重试',
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

    final previewBoundary = GlobalKey();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.buildAppTheme(Brightness.light),
          builder: (ctx, child) => RepaintBoundary(
            key: previewBoundary,
            child: MediaQuery(
              data: MediaQuery.of(ctx)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
          ),
          home: ThemeWorkshopScreen(
            initialState: initial,
            draftStore: draftStore,
            appVersion: '1.7.12',
            pickFilePath: (_) async =>
                throw PlatformException(code: 'permission_denied'),
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

    await _captureWorkshop(tester, previewBoundary, 'theme-settings');

    // 修改种子色后，预览组件的主题主色立即跟随变化。
    await tester
        .ensureVisible(find.byKey(const ValueKey('workshop-seed-hex-input')));
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

    Future<void> category(String name, [String? tab]) async {
      final chip = find.byKey(ValueKey('workshop-category-$name'));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      if (tab != null) {
        final child = find.byKey(ValueKey('workshop-tab-$tab'));
        await tester.ensureVisible(child);
        await tester.tap(child);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    }

    for (final (name, tab) in [
      ('colors', 'courses'),
      ('wallpapers', null),
      ('cards', 'layout'),
      ('cards', 'decoration'),
      ('navigation', null),
      ('desktop', 'launcherIcon'),
      ('desktop', 'widgets'),
      ('packages', null),
    ]) {
      await category(name, tab);
    }

    final thumbnail = find.byKey(const ValueKey('workshop-preview-thumbnail'));
    await tester.ensureVisible(thumbnail);
    await tester.tap(thumbnail);
    await tester.pumpAndSettle();
    expect(find.text('全屏预览'), findsOneWidget);
    for (final label in ['加载', '空态', '失败', '权限']) {
      final state = find.widgetWithText(ChoiceChip, label);
      await tester.ensureVisible(state);
      await tester.tap(state);
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '正常'));
    await tester.tap(find.widgetWithText(ChoiceChip, '正常'));
    await tester.pumpAndSettle();
    await _captureWorkshop(tester, previewBoundary, 'fullscreen-preview');
    await tester.tap(find.byKey(const ValueKey('home-themed-header-info')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('workshop-editor-layout')), findsOneWidget);

    await category('wallpapers');
    final chooseWallpaper =
        find.byKey(const ValueKey('workshop-wallpaper-portrait'));
    await tester.ensureVisible(chooseWallpaper);
    await tester.tap(chooseWallpaper);
    await tester.pumpAndSettle();
    expect(find.text('无法选取文件，请检查文件权限后重试。'), findsOneWidget);
    expect(initial.light.wallpapers['global']!['portrait'], wallFile.path);
    final darkMode = find.byKey(const ValueKey('workshop-brightness-dark'));
    await tester.ensureVisible(darkMode);
    await tester.tap(darkMode);
    await tester.pumpAndSettle();
    final copyBtn =
        find.byKey(const ValueKey('workshop-copy-light-wallpapers'));
    await tester.ensureVisible(copyBtn);
    await tester.tap(copyBtn);
    await tester.pump();
    expect(initial.dark.wallpapers['global']!['blur'], 2.0);
    initial.dark.wallpapers['global']!['blur'] = 8.0;
    expect(initial.light.wallpapers['global']!['blur'], 2.0);

    // 5. 切回浅色“装饰”Tab：调整贴纸前后层次，重置贴纸 1 不影响贴纸 2
    final lightMode = find.byKey(const ValueKey('workshop-brightness-light'));
    await tester.ensureVisible(lightMode);
    await tester.tap(lightMode);
    await tester.pumpAndSettle();
    await category('cards', 'decoration');

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
    await category('colors');
    await tester
        .ensureVisible(find.byKey(const ValueKey('workshop-seed-hex-input')));
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

  testWidgets('换壁纸和页头背景直接应用，经典默认主题同步编辑器且支持撤回', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await provider.setThemeMode(ThemeMode.light);
    final initial = ThemeWorkshopStateData.fromDefault();
    final photo = File(path.join(temp.path, 'photo.png'));
    await tester.runAsync(() => photo.writeAsBytes(themeImage(240, 360)));
    Uint8List? exported;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.buildAppTheme(Brightness.light),
          home: RepaintBoundary(
            key: boundary,
            child: ThemeWorkshopScreen(
              initialState: initial,
              draftStore: ThemeWorkshopDraftStore(
                themesDirectory: Directory(path.join(temp.path, 'themes')),
              ),
              pickFilePath: (_) async => photo.path,
              saveExportFile: (_, bytes) async {
                exported = bytes;
                return null;
              },
            ),
          ),
        ),
      ),
    );
    Future<void> tapAndWait(Finder target, {bool Function()? until}) async {
      await tester.ensureVisible(target);
      await tester.runAsync(() async {
        await tester.tap(target);
        await tester.pump();
      });
      await waitForEmojiWork(tester);
      if (until != null) {
        for (var i = 0; i < 300 && !until(); i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(until(), isTrue);
      }
      expect(tester.takeException(), isNull);
    }

    await tapAndWait(find.byKey(const ValueKey('workshop-category-wallpapers')));
    await tapAndWait(find.byKey(const ValueKey('workshop-wallpaper-portrait')),
        until: () => initial.light.wallpapers['global'] != null);
    final apply = find.byKey(const ValueKey('workshop-apply'));
    await tapAndWait(apply);
    final wallpaper = provider.backgroundImage!;
    expect(wallpaper, contains(path.join('themes', 'user')));

    await tapAndWait(find.byKey(const ValueKey('workshop-category-cards')));
    await tapAndWait(find.byKey(const ValueKey('workshop-tab-decoration')));
    await tapAndWait(find.text('选择背景图'),
        until: () => initial.light.decorations['home']?['background'] != null);
    await tapAndWait(apply);
    final decoration = provider.appearance.group(ThemeGroup.decoration)!;
    final header = decoration['light']['home']['background']['image'] as String;
    expect(header, contains(path.join('themes', 'user')));
    expect(await tester.runAsync(() => File(header).exists()), isTrue);
    expect(provider.backgroundImage, wallpaper);
    await tapAndWait(find.text('移除背景图'));
    await tapAndWait(apply);
    expect(provider.appearance.group(ThemeGroup.decoration)!['light']['home']?
        ['background'], isNull);
    expect(await tester.runAsync(provider.installedThemes), isEmpty);

    await tapAndWait(find.byKey(const ValueKey('workshop-category-packages')));
    await tapAndWait(find.byKey(const ValueKey('theme-original-default')));
    expect(provider.isCleanBackgroundMode, isTrue);
    expect(provider.hasThemeColors, isFalse);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull,
        reason: '切换默认主题后同步编辑器，旧草稿不能覆盖默认主题');
    await _captureWorkshop(tester, boundary, 'classic-default-workshop');
    await tapAndWait(find.widgetWithText(OutlinedButton, '恢复上一个外观'));
    expect(provider.backgroundImage, wallpaper);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    await tapAndWait(find.byKey(const ValueKey('workshop-export-button')));
    await tapAndWait(find.text('保存文件'), until: () => exported != null);
    expect(exported, isNotNull);
    final pack = await tester.runAsync(
        () => ThemePackCodec.decode(exported!, appVersion: '9.0.0'));
    expect(pack!.manifest.data['preview']['light'], endsWith('.jpg'));
    expect(pack.manifest.groups, contains(ThemeGroup.wallpapers));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
  });

  testWidgets('主题直接应用与保存失败重试，保留设备壁纸和其他主题组', (tester) async {
    await provider.setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
    await provider.setBackgroundImage('morenbeijing.jpeg');
    final draftStore = ThemeWorkshopDraftStore(
      themesDirectory: Directory(path.join(temp.path, 'themes')),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.buildAppTheme(Brightness.light),
          home:
              ThemeWorkshopScreen(draftStore: draftStore, appVersion: '1.7.12'),
        ),
      ),
    );
    final apply = find.byKey(const ValueKey('workshop-apply'));
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    final preview = tester.widget<ThemeWorkshopSampleStage>(
        find.byType(ThemeWorkshopSampleStage));
    expect(preview.appearance.group(ThemeGroup.navigation)!['style'], 'floating');
    final preset = find.byKey(const ValueKey('workshop-seed-海盐蓝'));
    await tester.ensureVisible(preset);
    await tester.tap(preset);
    await tester.pump();
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);

    Future<void> applyAndWait() async {
      await tester.runAsync(() async {
        await tester.tap(apply);
        await tester.pump();
      });
      await waitForEmojiWork(tester);
    }

    prefs.failAppearanceWrite = true;
    await applyAndWait();
    expect(find.text('主题应用失败，编辑内容已保留，请重试。'), findsOneWidget);
    expect(provider.hasThemeColors, isFalse);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    prefs.failAppearanceWrite = false;
    await applyAndWait();
    expect(find.text('主题已应用'), findsOneWidget);
    expect(provider.appearance.group(ThemeGroup.colors)?['light']['seedColor'],
        '#2F7FD8');
    expect(provider.appearance.group(ThemeGroup.wallpapers), isNull);
    expect(provider.backgroundImage, 'morenbeijing.jpeg');
    expect(provider.appearance.group(ThemeGroup.widgets), isNull);
    expect(await tester.runAsync(provider.installedThemes), isEmpty,
        reason: '本地修改直接保存外观，不生成并安装主题包');
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _captureWorkshop(
    WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['THEME_WORKSHOP_QA_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final render =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await render.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final folder = await Directory(directory).create(recursive: true);
    await File(path.join(folder.path, '$name.png'))
        .writeAsBytes(png!.buffer.asUint8List());
  });
}
