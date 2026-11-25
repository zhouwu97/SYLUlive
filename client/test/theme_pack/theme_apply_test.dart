import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_renderer.dart';
import 'package:shenliyuan/widgets/liquid_bottom_nav.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';
import 'package:shenliyuan/widgets/app_surface_transition.dart';
import '../helpers/active_backdrop_filters.dart';
import 'package:shenliyuan/features/theme_pack/installed_themes_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_appearance.dart';
import 'package:shenliyuan/features/theme_pack/theme_import_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_layout_decoration_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_store.dart';
import 'package:shenliyuan/features/theme_pack/theme_presentation.dart';
import 'package:shenliyuan/features/theme_pack/theme_hero_layer.dart';
import 'package:shenliyuan/features/theme_pack/theme_section.dart';
import 'package:shenliyuan/features/theme_pack/theme_trial_banner.dart';
import 'package:shenliyuan/widgets/campus/campus_header.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_palette.dart';
import 'package:shenliyuan/models/schedule_color_option.dart';
import 'package:shenliyuan/utils/app_navigator.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/widgets/floating_bottom_nav.dart';
import 'package:shenliyuan/features/theme_pack/theme_navigation_images.dart';
import 'theme_pack_test.dart' show themeFixture, themeImage, themeArchive;
import '../helpers/load_test_fonts.dart';
import '../helpers/emoji_flow_qa.dart'
    show settleEmojiQAImages, waitForEmojiWork;

class _FailingPreferences extends MemoryPreferencesStore {
  bool fail = false;
  Completer<void>? hold;
  final entered = Completer<void>();
  @override
  Future<bool> setString(String key, String value) async {
    if (key == ThemeProvider.appearanceKey) {
      if (!entered.isCompleted) entered.complete();
      await hold?.future;
      if (fail) return false;
    }
    return super.setString(key, value);
  }
}

class _LoadingStore extends ThemePackStore {
  _LoadingStore(Directory directory) : super(directory: directory);
  final pending = Completer<List<InstalledTheme>>();
  bool failed = true;
  @override
  Future<void> clearStaging({String? keepIncomingPath}) async {}
  @override
  Future<List<InstalledTheme>> list() async {
    final themes = await pending.future;
    if (failed) throw const FileSystemException('unavailable');
    return themes;
  }
}

PreparedThemePack _pack(
    {String suffix = '1',
    int version = 1,
    String color = '#A02080',
    bool wallpaper = false,
    bool material = false,
    bool navigation = false,
    String navigationStyle = 'normal'}) {
  final json = themeFixture(
      id: '00000000-0000-4000-8000-00000000000$suffix', version: version)
    ..['shape'] = 'rounded';
  for (final mode in ['light', 'dark']) {
    json[mode]['tokens']['primary'] = color;
    json[mode]['tokens']['onPrimary'] = '#FFFFFF';
    if (wallpaper) {
      json[mode]['wallpapers'] = {
        'global': {
          'portrait':
              mode == 'light' ? 'wallpaper/paper.png' : 'wallpaper/night.png',
          'fit': 'contain',
          'focalX': .2,
          'focalY': .8,
          'scrim': .1
        },
        'home': null,
      };
    }
    if (material) {
      json[mode]['componentOpacity'] = mode == 'light' ? .8 : .95;
      json[mode]['frostedGlass'] = {
        'enabled': true,
        'strength': mode == 'light' ? .3 : .7
      };
    }
  }
  if (navigation) {
    json['bottomNav'] = {
      'style': navigationStyle,
      'iconTint': 'template',
      'icons': {
        'home': {'normal': 'icons/home.png', 'selected': 'icons/selected.png'},
      }
    };
  }
  return PreparedThemePack(ThemeManifest.parse(json, appVersion: '9.0.0'), {
    'preview/cover.png': themeImage(1080, 2340),
    if (wallpaper) ...{
      'wallpaper/paper.png': img.encodePng(img.fill(
          img.Image(width: 160, height: 240),
          color: img.ColorRgb8(225, 238, 244))),
      'wallpaper/night.png': img.encodePng(img.fill(
          img.Image(width: 160, height: 240),
          color: img.ColorRgb8(24, 35, 54))),
    },
    if (navigation) ...{
      'icons/home.png': themeImage(48, 48),
      'icons/selected.png': themeImage(48, 48)
    },
  });
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
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sltheme-test-');
    store =
        ThemePackStore(directory: Directory(path.join(temp.path, 'themes')));
    AppPreferencesStore.setCustomInstance(MemoryPreferencesStore());
    provider = ThemeProvider(loadOnStart: false, themePackStore: store);
    await provider.loadThemeForTesting();
    await provider.installedThemes();
    currentHomeTabIndex.value = 0;
  });
  tearDown(() async {
    provider.dispose();
    AppPreferencesStore.setCustomInstance(null);
    await temp.delete(recursive: true);
  });

  test('完整应用主题同步全部外观设置，覆盖旧液态关闭状态并在重启后保持', () async {
    await provider.setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
    await provider.setBottomNavClearMaterial(true);
    final theme = await provider.installTheme(_pack(
      wallpaper: true,
      material: true,
      navigation: true,
      navigationStyle: 'liquid_glass',
    ));
    await provider.applyInstalledTheme(theme, ThemeGroup.applicable);
    expect(provider.bottomNavStyle, BottomNavStyle.liquidGlass);
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.highQuality);
    expect(provider.bottomNavAnimationIntensity, 1);
    expect(provider.bottomNavClearMaterial, isFalse);
    expect(provider.bottomNavShaderEnabled, isTrue);
    expect(provider.backgroundMode, AppBackgroundMode.custom);
    expect(provider.componentOpacity, .8);
    expect(provider.frostedGlassStrength, .3);
    expect(provider.frostedGlassCustomStrength, .3);
    expect(provider.customComponentOpacityLevel, closeTo(.2, .0001));
    await provider.setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
    expect(provider.componentOpacity, .8);
    expect(provider.frostedGlassStrength, .3);
    await provider.setThemeMode(ThemeMode.dark);
    expect(provider.componentOpacity, .95);
    expect(provider.frostedGlassStrength, .7);
    final restarted = ThemeProvider(loadOnStart: false, themePackStore: store);
    addTearDown(restarted.dispose);
    await restarted.loadThemeForTesting();
    expect(restarted.bottomNavPerformanceMode, BottomNavPerformanceMode.highQuality);
    expect(restarted.bottomNavAnimationIntensity, 1);
    expect(restarted.bottomNavClearMaterial, isFalse);
    expect(restarted.backgroundMode, AppBackgroundMode.custom);
    expect(restarted.componentOpacity, .95);
  });

  test('完整切换简洁主题还原未提供的外观分组，部分混搭保留未勾选分组', () async {
    await provider.setBackgroundImage('morenbeijing.jpeg');
    await provider.setFrostedGlassStrength(.8);
    final detailed = await provider.installTheme(_pack(
      wallpaper: true, material: true, navigation: true));
    final simple = await provider.installTheme(_pack(suffix: '2'));
    await provider.applyInstalledTheme(detailed, ThemeGroup.applicable);
    await provider.applyInstalledTheme(simple, {ThemeGroup.colors});
    expect(provider.backgroundImage, contains(detailed.directory));
    expect(provider.componentOpacity, .8);
    await provider.applyInstalledTheme(simple, ThemeGroup.applicable);
    expect(provider.backgroundImage, isNull);
    expect(provider.isCleanBackgroundMode, isTrue);
    expect(provider.effectiveComponentOpacity, 1);
    expect(provider.frostedGlass, isFalse);
    expect(provider.bottomNavStyle, BottomNavStyle.liquidGlass);
    expect(provider.appearance.group(ThemeGroup.navigation)!['icons'], isEmpty);
    await provider.restorePreviousAppearance();
    expect(provider.backgroundImage, contains(detailed.directory));
    expect(provider.componentOpacity, .8);
    expect(provider.bottomNavStyle, BottomNavStyle.normal);
  });

  test('工坊修改导航样式同步效果，同样式的图标编辑保留当前强度', () async {
    final theme = await provider.installTheme(_pack(navigation: true));
    await provider.applyInstalledTheme(theme, ThemeGroup.defaultApply);
    final navigation = provider.appearance.group(ThemeGroup.navigation)!;
    await provider.applyEditedAppearance(ThemeAppearance({
      'navigation': {...navigation, 'style': 'liquid_glass', 'motion': null},
    }), {ThemeGroup.navigation});
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.highQuality);
    expect(provider.bottomNavAnimationIntensity, 1);
    await provider.setBottomNavAnimationIntensity(.4);
    await provider.applyEditedAppearance(ThemeAppearance({
      'navigation': {
        ...provider.appearance.group(ThemeGroup.navigation)!,
        'style': 'liquid_glass',
        'motion': null,
        'iconTint': 'original',
      },
    }), {ThemeGroup.navigation});
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.custom);
    expect(provider.bottomNavAnimationIntensity, .4);
    expect(provider.appearance.group(ThemeGroup.navigation)!['iconTint'], 'original');
  });

  test('按组混搭、明暗切换和重启，保留手动偏好及来源', () async {
    final prefs = await AppPreferencesStore.getInstance();
    await provider.setBackgroundImage('morenbeijing.jpeg');
    await provider.setThemeMode(ThemeMode.dark);
    final a = await provider.installTheme(_pack());
    final b = await provider.installTheme(_pack(suffix: '2', wallpaper: true));
    await provider
        .applyInstalledTheme(a, {ThemeGroup.colors, ThemeGroup.shape});
    await provider.applyInstalledTheme(b, {ThemeGroup.wallpapers});
    expect(provider.appearance.group(ThemeGroup.colors)!['source']['themeId'],
        a.manifest.id);
    expect(provider.backgroundImage, contains(b.directory));
    expect(prefs.getString('background_image'), 'morenbeijing.jpeg');
    expect(provider.themeMode, ThemeMode.dark);
    final restarted = ThemeProvider(themePackStore: store);
    await restarted.installedThemes();
    expect(restarted.buildAppTheme(Brightness.light).colorScheme.primary,
        const Color(0xffa02080));
    expect(
        restarted.buildAppTheme(Brightness.dark).extension<AppShape>()!.preset,
        AppShapePreset.rounded);
    expect(restarted.backgroundImage, provider.backgroundImage);
    restarted.dispose();
    await provider.setBackgroundImage('another.jpg');
    expect(provider.backgroundImage, 'another.jpg');
    expect(provider.hasThemeColors, isTrue);
    await provider.restorePreviousAppearance();
    expect(provider.backgroundImage, 'morenbeijing.jpeg');
    expect(provider.hasThemeColors, isTrue);
    await provider.restorePreviousAppearance();
    expect(provider.backgroundImage, 'another.jpg');
  });

  test('安装新版后撤回旧版，删除主题仍保留当前和上一个外观的文件', () async {
    final first = await provider.installTheme(_pack(wallpaper: true));
    await provider
        .applyInstalledTheme(first, {ThemeGroup.colors, ThemeGroup.wallpapers});
    final second = await provider
        .installTheme(_pack(version: 2, color: '#2277AA', wallpaper: true));
    await provider.applyInstalledTheme(
        second, {ThemeGroup.colors, ThemeGroup.wallpapers});
    expect((await provider.installedThemes()).single.manifest.version, 2);
    await provider.deleteInstalledTheme(first.manifest.id);
    expect(await provider.installedThemes(), isEmpty);
    expect(await Directory(first.directory).exists(), isTrue);
    expect(await Directory(second.directory).exists(), isTrue);
    await provider.restorePreviousAppearance();
    expect(provider.buildAppTheme(Brightness.light).colorScheme.primary,
        const Color(0xffa02080));
    expect(provider.backgroundImage, contains(first.directory));
    await provider.restoreManualAppearance();
    expect(provider.hasThemeColors, isFalse);
    expect(await Directory(second.directory).exists(), isFalse);
    expect(await Directory(first.directory).exists(), isTrue);
  });

  test('内置默认主题时恢复默认外观回到该主题，且可撤回到商城主题', () async {
    final builtIn = await provider.installTheme(_pack(wallpaper: true));
    await provider.applyInstalledTheme(
        builtIn, ThemeProvider.builtInDefaultGroups);
    final store = await provider
        .installTheme(_pack(suffix: '3', color: '#2277AA', material: true));
    await provider.applyInstalledTheme(store, ThemeGroup.applicable);
    await provider.restoreManualAppearance(defaultTheme: builtIn);
    expect(provider.buildAppTheme(Brightness.light).colorScheme.primary,
        const Color(0xffa02080));
    expect(provider.backgroundImage, contains(builtIn.directory));
    // 默认外观只含内置主题自带的分组，商城主题的材质不残留。
    expect(provider.appearance.group(ThemeGroup.material), isNull);
    await provider.restorePreviousAppearance();
    expect(provider.appearance.group(ThemeGroup.colors)!['source']['themeId'],
        store.manifest.id);
  });

  test('本机编辑只保存所选分组，资源独立保存、重启与撤回可恢复', () async {
    final installed = await provider.installTheme(
        _pack(wallpaper: true, material: true, navigation: true));
    await provider.applyInstalledTheme(installed, ThemeGroup.applicable);
    final photo = File(path.join(temp.path, 'selected.png'));
    await photo.writeAsBytes(themeImage(200, 300));
    final edited = ThemeAppearance({
      'wallpapers': {
        'source': null,
        'light': {
          'global': {'portrait': photo.path, 'fit': 'cover'}
        },
        'dark': <String, dynamic>{},
      },
    });
    await provider.applyEditedAppearance(edited, {ThemeGroup.wallpapers});
    final adopted = provider.backgroundImage!;
    expect(adopted, contains(path.join('themes', 'user')));
    expect(adopted, isNot(photo.path));
    expect(provider.isThemeVersionActive(installed.manifest.id, 1), isTrue);
    expect(provider.componentOpacity, .8);
    expect(provider.bottomNavStyle, BottomNavStyle.normal);
    expect((await provider.installedThemes()).length, 1);
    await photo.delete();
    final restarted = ThemeProvider(loadOnStart: false, themePackStore: store);
    addTearDown(restarted.dispose);
    await restarted.loadThemeForTesting();
    expect(restarted.backgroundImage, adopted);
    expect(await File(adopted).exists(), isTrue);
    await restarted.setThemeMode(ThemeMode.dark);
    expect(restarted.isCleanBackgroundMode, isTrue);
    await restarted.restorePreviousAppearance();
    expect(restarted.backgroundImage, contains(installed.directory));
    await restarted.restorePreviousAppearance();
    await restarted.setThemeMode(ThemeMode.light);
    expect(restarted.backgroundImage, adopted);
  });

  test('经典默认主题恢复原始配色与布局，覆盖手动背景，保留设备偏好并支持撤回和重启', () async {
    await provider.setBackgroundImage('morenbeijing.jpeg');
    await provider.setComponentOpacity(.8);
    await provider.setThemeMode(ThemeMode.dark);
    final installed = await provider.installTheme(
        _pack(wallpaper: true, material: true, navigation: true));
    await provider.applyInstalledTheme(installed, ThemeGroup.applicable);
    await provider.updateHeaderLayout('home', {'preset': 'immersive'});
    await provider.startTrial(installed: installed, groups: {ThemeGroup.colors});
    await provider.applyOriginalDefaultAppearance();
    expect(provider.isInTrial, isFalse);
    expect(provider.hasThemeColors, isFalse);
    expect(provider.isCleanBackgroundMode, isTrue);
    expect(provider.backgroundImage, isNull);
    expect(provider.effectiveComponentOpacity, 1);
    expect(provider.frostedGlass, isFalse);
    expect(provider.bottomNavStyle, BottomNavStyle.liquidGlass);
    expect(provider.appearance.group(ThemeGroup.layout), isNull);
    expect(provider.appearance.group(ThemeGroup.navigation)!['source']['name'],
        '默认主题（经典）');
    expect(provider.appearance.group(ThemeGroup.widgets)!['source']['themeId'],
        installed.manifest.id);
    expect(provider.themeMode, ThemeMode.dark);
    for (final brightness in Brightness.values) {
      expect(provider.buildAppTheme(brightness).extension<AppPalette>()!.toJson(),
          AppPalette.defaults(brightness).toJson());
    }
    final restarted = ThemeProvider(loadOnStart: false, themePackStore: store);
    addTearDown(restarted.dispose);
    await restarted.loadThemeForTesting();
    expect(restarted.appearance.group(ThemeGroup.navigation)!['source']['name'],
        '默认主题（经典）');
    expect(restarted.isCleanBackgroundMode, isTrue);
    await restarted.restorePreviousAppearance();
    expect(restarted.backgroundImage, contains(installed.directory));
    expect(restarted.hasThemeColors, isTrue);
    expect(restarted.appearance.group(ThemeGroup.layout)!['value']['home']
        ['preset'], 'immersive');
    expect(await File(restarted.backgroundImage!).exists(), isTrue);
  });

  test('撤回快照不读取后来的手动偏好；恢复手动外观使用最新手动值', () async {
    await provider.setBackgroundImage('before.jpg');
    await provider.setComponentOpacity(.9);
    final theme =
        await provider.installTheme(_pack(wallpaper: true, material: true));
    await provider.applyInstalledTheme(theme, ThemeGroup.applicable);
    await provider.setBackgroundImage('after.jpg');
    await provider.setComponentOpacity(.85);
    await provider.restorePreviousAppearance();
    expect(provider.backgroundImage, 'before.jpg');
    expect(provider.componentOpacity, .9);
    await provider.restoreManualAppearance();
    expect(provider.backgroundImage, 'after.jpg');
    expect(provider.componentOpacity, .85);
  });

  test('原手动本地壁纸迁入受管目录，连续应用和重启后恢复仍保留原图', () async {
    final old = File(path.join(temp.path, 'wallpapers', 'custom', 'old.png'));
    await old.parent.create(recursive: true);
    await old.writeAsBytes(themeImage(8, 8));
    await File('${old.path}.verified').writeAsString('ok');
    await provider.setBackgroundImage(old.path);
    final adopted = provider.backgroundImage!;
    expect(adopted, contains(path.join('themes', 'user')));
    expect(await old.exists(), isFalse);
    expect(await File('$adopted.verified').exists(), isTrue);
    for (final suffix in ['1', '2']) {
      final theme =
          await provider.installTheme(_pack(suffix: suffix, wallpaper: true));
      await provider.applyInstalledTheme(theme, {ThemeGroup.wallpapers});
    }
    await provider.restoreManualAppearance();
    expect(provider.backgroundImage, adopted);
    expect(await File(adopted).exists(), isTrue);
    final external = File(path.join(temp.path, 'photo.png'));
    await external.writeAsBytes(themeImage(8, 8));
    await provider.setBackgroundImage(external.path);
    expect(await external.exists(), isTrue);
    expect(await File(adopted).exists(), isFalse);
  });

  test('主题材质分明暗；平面背景也能编辑，手动调节不清掉配色与图标', () async {
    final theme =
        await provider.installTheme(_pack(material: true, navigation: true));
    await provider.applyInstalledTheme(theme, ThemeGroup.applicable);
    await provider.setThemeMode(ThemeMode.light);
    expect(provider.effectiveComponentOpacity, .8);
    expect(provider.frostedGlass, isTrue);
    expect(provider.canCustomizeCardMaterial, isTrue);
    await provider.setComponentOpacity(.86);
    expect(provider.customComponentOpacityLevel, .44);
    await provider.setThemeMode(ThemeMode.dark);
    expect(provider.effectiveComponentOpacity, .95);
    expect(provider.frostedGlassStrength, .7);
    await provider.setBottomNavAnimationIntensity(.4);
    expect(provider.bottomNavStyle, BottomNavStyle.liquidGlass);
    expect(provider.appearance.group(ThemeGroup.navigation)!['icons']['home'],
        isNotNull);
    expect(provider.hasThemeColors, isTrue);
    await provider.setThemeMode(ThemeMode.light);
    expect(provider.effectiveComponentOpacity, .86);
  });

  test('存储失败不应用一半外观，队列失败后可重试且只保留一个上次快照', () async {
    final preferences = _FailingPreferences();
    AppPreferencesStore.setCustomInstance(preferences);
    await provider.setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
    final theme = await provider.installTheme(_pack(material: true));
    await provider.startTrial(installed: theme, groups: ThemeGroup.defaultApply);
    preferences.fail = true;
    await expectLater(provider.applyInstalledTheme(theme, ThemeGroup.defaultApply),
        throwsA(isA<FileSystemException>()));
    expect(provider.isInTrial, isTrue);
    expect(provider.persistedAppearance.group(ThemeGroup.colors), isNull);
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.highQuality);
    await provider.endTrial();
    expect(provider.hasThemeColors, isFalse);
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
    expect(provider.componentOpacity, 1);
    expect(preferences.getString(ThemeProvider.previousAppearanceKey), isNull);
    preferences.fail = false;
    await provider.applyInstalledTheme(theme, ThemeGroup.defaultApply);
    expect(provider.hasThemeColors, isTrue);
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.highQuality);
    expect(provider.componentOpacity, .8);
    expect(provider.frostedGlassStrength, .3);
    expect(
        preferences.getString(ThemeProvider.previousAppearanceKey), isNotNull);
  });

  test('应用未完成时重选壁纸，按操作次序保存，重启不会回到旧主题壁纸', () async {
    final preferences = _FailingPreferences()..hold = Completer<void>();
    AppPreferencesStore.setCustomInstance(preferences);
    final theme = await provider.installTheme(_pack(wallpaper: true));
    final applying = provider
        .applyInstalledTheme(theme, {ThemeGroup.colors, ThemeGroup.wallpapers});
    await preferences.entered.future;
    final manual = provider.setBackgroundImage('last.jpg');
    preferences.hold!.complete();
    await Future.wait([applying, manual]);
    final restarted = ThemeProvider(themePackStore: store);
    await restarted.installedThemes();
    expect(restarted.backgroundImage, 'last.jpg');
    expect(restarted.hasThemeColors, isTrue);
    restarted.dispose();
  });

  test('快速连续完整应用主题按顺序提交，最后一套生效且可撤回完整前一套', () async {
    final preferences = _FailingPreferences();
    AppPreferencesStore.setCustomInstance(preferences);
    final a = await provider.installTheme(_pack(wallpaper: true, material: true));
    final b = await provider.installTheme(_pack(suffix: '2', color: '#43A047'));
    preferences.hold = Completer<void>();
    final first = provider.applyInstalledTheme(a, ThemeGroup.defaultApply);
    await preferences.entered.future;
    final second = provider.applyInstalledTheme(b, ThemeGroup.defaultApply);
    preferences.hold!.complete();
    await Future.wait([first, second]);
    expect(provider.buildAppTheme(Brightness.light).colorScheme.primary,
        const Color(0xFF43A047));
    expect(provider.backgroundImage, isNull);
    expect(provider.componentOpacity, 1);
    await provider.restorePreviousAppearance();
    expect(provider.buildAppTheme(Brightness.light).colorScheme.primary,
        const Color(0xFFA02080));
    expect(provider.backgroundImage, contains(a.directory));
    expect(provider.componentOpacity, .8);
  });

  test('分享安装包后可重新校验，重复安装不覆盖旧版本', () async {
    final theme =
        await provider.installTheme(_pack(wallpaper: true, navigation: true));
    final exported = await store.export(theme);
    final decoded = await ThemePackCodec.decode(exported, appVersion: '9.0.0');
    expect(decoded.manifest.id, theme.manifest.id);
    expect(decoded.contents.keys,
        containsAll(['wallpaper/paper.png', 'icons/home.png']));
    await expectLater(
        provider.installTheme(decoded), throwsA(isA<ThemePackError>()));
    expect((await provider.installedThemes()).length, 1);
    expect(
        await Directory(path.join(temp.path, 'themes', '.staging'))
            .list()
            .isEmpty,
        isTrue);
  });

  Widget host(Widget screen,
          {ThemeProvider? theme,
          Brightness brightness = Brightness.light,
          double scale = 1}) =>
      ChangeNotifierProvider.value(
          value: theme ?? provider,
          child: MaterialApp(
            theme: (theme ?? provider).buildAppTheme(brightness),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: screen,
          ));

  testWidgets('本机列表加载、失败、重试、空态', (tester) async {
    final failing = _LoadingStore(Directory(path.join(temp.path, 'other')));
    final theme = ThemeProvider(loadOnStart: false, themePackStore: failing);
    await tester.pumpWidget(host(const InstalledThemesScreen(), theme: theme));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    failing.pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.textContaining('无法读取本机主题'), findsOneWidget);
    failing.failed = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('还没有本机主题'), findsOneWidget);
    expect(find.byKey(const ValueKey('installed-original-default')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('installed-original-default')));
      await tester.pump();
    });
    await waitForEmojiWork(tester);
    expect(find.text('已应用默认主题（经典）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    theme.dispose();
  });
  testWidgets('主题材质在纯色背景实际绘制；液态导航图片切换不回填旧图', (tester) async {
    await tester.runAsync(() async {
      final theme = await provider.installTheme(_pack(material: true));
      await provider.applyInstalledTheme(theme, {ThemeGroup.material});
    });
    await tester
        .pumpWidget(host(const Scaffold(body: AppCard(child: Text('材质')))));
    await tester.pumpAndSettle();
    expect(activeBackdropFilters(), findsOneWidget);
    await tester.runAsync(provider.restorePreviousAppearance);
    await tester.pumpAndSettle();
    expect(provider.canCustomizeCardMaterial, isFalse);
    expect(activeBackdropFilters(), findsNothing);
    final boundary = GlobalKey();
    final red = MemoryImage(img.encodePng(img.fill(
        img.Image(width: 48, height: 48),
        color: img.ColorRgb8(255, 0, 0))));
    final blue = MemoryImage(img.encodePng(img.fill(
        img.Image(width: 48, height: 48),
        color: img.ColorRgb8(0, 0, 255))));
    Widget navigation(ImageProvider image) => host(Scaffold(
        body: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                    width: 360,
                    height: 64,
                    child: LiquidGlassRenderer(
                      lens: const Rect.fromLTWH(4, 4, 70, 56),
                      press: 0,
                      pointer: Offset.zero,
                      labels: LiquidBottomNav.labels,
                      icons: LiquidBottomNav.icons,
                      badges: const {},
                      accent: Colors.green,
                      enabled: false,
                      originalIcons: true,
                      themeImages: {0: (image, image)},
                    ))))));
    await tester.pumpWidget(navigation(red));
    await tester.pumpWidget(navigation(blue));
    await settleEmojiQAImages(tester, boundary.currentContext!, [blue]);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final shot = await (boundary.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage();
      final pixels = await shot.toByteData(format: ui.ImageByteFormat.rawRgba);
      const offset = (24 * 360 + 40) * 4;
      expect(pixels!.getUint8(offset), 0);
      expect(pixels.getUint8(offset + 2), 255);
      shot.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('导入取消、错误文件、权限失败后可重新选择；离开页面后旧读取不回填', (tester) async {
    final completer = Completer<String?>();
    var calls = 0;
    Future<String?> pick() async {
      calls++;
      if (calls == 1) return null;
      if (calls == 2) return 'bad.txt';
      if (calls == 3) throw const FileSystemException('denied');
      return completer.future;
    }

    await tester.pumpWidget(
        host(ThemeImportScreen(pickFile: pick, appVersion: '9.0.0')));
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('选择主题文件'));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('文件访问权限'), findsOneWidget);
    await tester.tap(find.text('选择主题文件'));
    await tester.pump();
    expect(find.text('正在检查主题与资源…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    completer.complete('bad.txt');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(provider.hasThemeColors, isFalse);
  });
  testWidgets('主题需要更高版本时提供现有更新入口，不保存包', (tester) async {
    final file = File(path.join(temp.path, 'future.sltheme'));
    await tester.runAsync(() => file.writeAsBytes(
        themeArchive(themeFixture()..['minAppVersion'] = '99.0.0')));
    await tester.pumpWidget(host(ThemeImportScreen(
        pickFile: () async => file.path, appVersion: '1.0.0')));
    await tester.tap(find.text('选择主题文件'));
    await waitForEmojiWork(tester);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.textContaining('theme_app_too_old'), findsOneWidget);
    expect((await tester.runAsync(provider.installedThemes))!, isEmpty);
  });
  testWidgets('纯色主题材质下删除弹窗统一转场，取消保留列表和资源', (tester) async {
    late InstalledTheme installed;
    await tester.runAsync(() async {
      installed = await provider.installTheme(_pack(material: true));
      await provider.applyInstalledTheme(installed, {ThemeGroup.material});
    });
    final controlled = _LoadingStore(Directory(path.join(temp.path, 'other')))
      ..failed = false;
    controlled.pending.complete([installed]);
    final theme = ThemeProvider(themePackStore: controlled);
    await tester.pumpWidget(host(const InstalledThemesScreen(), theme: theme));
    await tester.pumpAndSettle();
    await settleEmojiQAImages(
        tester,
        tester.element(find.byType(InstalledThemesScreen)),
        tester
            .widgetList<Image>(find.byType(Image))
            .map((image) => image.image));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('将从本机主题列表移除'), findsOneWidget);
    expect(
        find.ancestor(
            of: find.byType(AppAlertDialog),
            matching: find.byType(AppSurfaceTransition)),
        findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('测试主题'), findsOneWidget);
    expect(await tester.runAsync(() => Directory(installed.directory).exists()),
        isTrue);
    await tester.pumpWidget(const SizedBox());
    theme.dispose();
  });

  testWidgets('完整文件导入预览、按组应用与重复点击门禁', (tester) async {
    await tester.runAsync(() async {
      await provider.setBackgroundImage('morenbeijing.jpeg');
      await provider.setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
    });
    final source = File(path.join(temp.path, 'import.sltheme'));
    await tester
        .runAsync(() => source.writeAsBytes(themeArchive(themeFixture())));
    await tester.pumpWidget(host(Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<bool>(
                          builder: (_) => ThemeImportScreen(
                              pickFile: () async => source.path,
                              appVersion: '9.0.0'))),
                  child: const Text('打开导入'),
                )))));
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('选择主题文件'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();
    expect(find.text('应用效果预览'), findsOneWidget);
    expect(find.textContaining('本机主题'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('保存并应用'));
      await tester.pump();
      await tester.tap(find.text('正在保存…'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(provider.hasThemeColors, isTrue);
    expect(provider.backgroundImage, isNull);
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.highQuality);
    expect(find.text('打开导入'), findsOneWidget);
    expect((await tester.runAsync(provider.installedThemes))!.length, 1);
    final confirmation = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(confirmation.persist, isFalse);
    expect(confirmation.duration, const Duration(seconds: 5));
    await tester.tap(find.text('撤销'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    expect(provider.hasThemeColors, isFalse);
    expect(provider.backgroundImage, 'morenbeijing.jpeg');
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    testWidgets('真实渲染 ${brightness.name}：360px、大字号、壁纸、导航和恢复入口', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late InstalledTheme theme;
      await tester.runAsync(() async {
        theme = await provider.installTheme(
            _pack(wallpaper: true, navigation: true, material: true));
        await provider.applyInstalledTheme(theme, ThemeGroup.applicable);
        await provider.setThemeMode(
            brightness == Brightness.light ? ThemeMode.light : ThemeMode.dark);
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(host(
          RepaintBoundary(
              key: boundary, child: ThemeImportScreen(installed: theme)),
          brightness: brightness,
          scale: 1.5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await settleEmojiQAImages(
          tester,
          boundary.currentContext!,
          tester
              .widgetList<Image>(find.byType(Image))
              .map((image) => image.image));
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final screenshot = await render.toImage();
        final bytes =
            await screenshot.toByteData(format: ui.ImageByteFormat.png);
        screenshot.dispose();
        final dir =
            await Directory('build/theme-p1-qa').create(recursive: true);
        await File('${dir.path}/preview-${brightness.name}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
      await tester.pumpWidget(host(
          Scaffold(
              body: const CustomBackgroundLayer(canvasSize: Size(360, 800)),
              bottomNavigationBar: FloatingBottomNav(
                  currentIndex: 0,
                  onTap: (_) {},
                  docked: true,
                  themeImages: themeNavigationImages(
                      provider.appearance.group(ThemeGroup.navigation)),
                  originalIcons: true)),
          brightness: brightness,
          scale: 1.5));
      await settleEmojiQAImages(
          tester,
          tester.element(find.byType(CustomBackgroundLayer)),
          tester
              .widgetList<Image>(find.byType(Image))
              .map((image) => image.image));
      await tester.pumpAndSettle();
      currentHomeTabIndex.value = 2;
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(
          RepaintBoundary(
            key: boundary,
            child: const Scaffold(body: SingleChildScrollView(child: ThemeSection())),
          ),
          brightness: brightness,
          scale: 1.5));
      await tester.pumpAndSettle();
      expect(find.text('恢复上一个外观'), findsOneWidget);
      final original = find.byKey(const ValueKey('theme-original-default'));
      await tester.ensureVisible(original);
      await tester.runAsync(() async {
        await tester.tap(original);
        await tester.pump();
      });
      await waitForEmojiWork(tester);
      expect(provider.hasThemeColors, isFalse);
      await tester.pumpWidget(host(
          RepaintBoundary(
            key: boundary,
            child: const Scaffold(body: SingleChildScrollView(child: ThemeSection())),
          ),
          brightness: brightness,
          scale: 1.5));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await render.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final dir = await Directory('build/theme-p1-qa').create(recursive: true);
        await File('${dir.path}/original-default-${brightness.name}.png')
            .writeAsBytes(png!.buffer.asUint8List());
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    });
  }

  test('全局试用会话不写偏好、重启自动结束，applyTrial 保存试用前快照', () async {
    final prefs = await AppPreferencesStore.getInstance();
    await provider.setBackgroundImage('before_trial.jpg');
    await provider.setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
    final uninstalled = _pack(suffix: '3', color: '#D84315', wallpaper: true);
    await provider.startTrial(
      pack: uninstalled,
      groups: ThemeGroup.defaultApply,
    );
    expect(provider.isInTrial, isTrue);
    expect(
      provider.buildAppTheme(Brightness.light).colorScheme.primary,
      const Color(0xffd84315),
    );
    expect(provider.usesThemeWallpapers, isTrue);
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.highQuality);
    expect(provider.bottomNavShaderEnabled, isTrue);
    expect(prefs.getString(ThemeProvider.appearanceKey), isNull);
    expect(prefs.getString(ThemeProvider.previousAppearanceKey), isNull);

    // 模拟进程被杀重启：偏好未写入，新实例回到原外观
    final restarted = ThemeProvider(themePackStore: store);
    await restarted.installedThemes();
    expect(restarted.isInTrial, isFalse);
    expect(restarted.hasThemeColors, isFalse);
    expect(restarted.backgroundImage, 'before_trial.jpg');
    expect(restarted.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
    restarted.dispose();

    // 重新开始试用并结束：恢复原外观且暂存目录清理
    await provider.startTrial(
      pack: uninstalled,
      groups: ThemeGroup.defaultApply,
    );
    final stagingDir = provider.trial!.stagingDirectory!;
    expect(await Directory(stagingDir).exists(), isTrue);
    await provider.endTrial();
    expect(provider.isInTrial, isFalse);
    expect(provider.hasThemeColors, isFalse);
    expect(provider.backgroundImage, 'before_trial.jpg');
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
    expect(await Directory(stagingDir).exists(), isFalse);

    // 再次试用并应用：持久化写入且可撤销回试用前外观
    await provider.startTrial(
      pack: uninstalled,
      groups: ThemeGroup.defaultApply,
    );
    await provider.applyTrial();
    expect(provider.isInTrial, isFalse);
    expect(provider.hasThemeColors, isTrue);
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.highQuality);
    expect(prefs.getString(ThemeProvider.appearanceKey), isNotNull);
    await provider.restorePreviousAppearance();
    expect(provider.hasThemeColors, isFalse);
    expect(provider.backgroundImage, 'before_trial.jpg');
    expect(provider.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
  });

  test('导出当前混搭外观包含最终生效参数与资源，并可在新环境重新导入', () async {
    final a = await provider.installTheme(
      _pack(suffix: '4', color: '#1E88E5', material: true),
    );
    final b = await provider.installTheme(
      _pack(suffix: '5', color: '#43A047', wallpaper: true, navigation: true),
    );
    await provider.applyInstalledTheme(
      a,
      {ThemeGroup.colors, ThemeGroup.shape, ThemeGroup.material},
    );
    await provider.applyInstalledTheme(
      b,
      {ThemeGroup.wallpapers, ThemeGroup.navigation},
    );
    await provider.setThemeMode(ThemeMode.light);
    await provider.setComponentOpacity(.86);
    await provider.setScheduleColorPreference(text: true, value: ScheduleColorOption.purple);
    await provider.setScheduleColorPreference(text: false, value: ScheduleColorOption.green);
    expect(provider.currentAppearanceSummary, contains('混搭外观'));

    final exportedBytes = await provider.exportCurrentAppearance(
      customName: '海盐混搭',
      authorName: '测试导出者',
      appVersion: '1.7.12',
    );
    final redecoded = await ThemePackCodec.decode(
      exportedBytes,
      appVersion: '9.0.0',
    );
    expect(redecoded.manifest.id, isNot(a.manifest.id));
    expect(redecoded.manifest.id, isNot(b.manifest.id));
    expect(redecoded.manifest.name, '海盐混搭');

    final targetDir = Directory(path.join(temp.path, 'reimport-themes'));
    final targetStore = ThemePackStore(directory: targetDir);
    AppPreferencesStore.setCustomInstance(MemoryPreferencesStore());
    final cleanProvider =
        ThemeProvider(loadOnStart: false, themePackStore: targetStore);
    await cleanProvider.loadThemeForTesting();
    final reinstalled = await cleanProvider.installTheme(redecoded);
    await cleanProvider.applyInstalledTheme(reinstalled, ThemeGroup.applicable);
    await cleanProvider.setThemeMode(ThemeMode.light);
    expect(
      cleanProvider.buildAppTheme(Brightness.light).colorScheme.primary,
      const Color(0xff1e88e5),
    );
    expect(
      cleanProvider
          .buildAppTheme(Brightness.light)
          .extension<AppShape>()!
          .preset,
      AppShapePreset.rounded,
    );
    expect(cleanProvider.effectiveComponentOpacity, .86);
    final palette = cleanProvider.buildAppTheme(Brightness.light).extension<AppPalette>()!;
    expect(palette.courseCardText, ScheduleColorOption.purple.color);
    expect(palette.coursePalette, everyElement(ScheduleColorOption.green.color));
    expect(cleanProvider.usesThemeWallpapers, isTrue);
    expect(
      cleanProvider.appearance.group(ThemeGroup.navigation)!['icons']['home'],
      isNotNull,
    );
    cleanProvider.dispose();
  });

  testWidgets('全局试用横条跨页面常驻，支持结束与应用', (tester) async {
    final installed = await tester.runAsync(
      () => provider.installTheme(_pack(suffix: '6', color: '#8E24AA')),
    );
    final tabNotifier = ValueNotifier<int>(0);
    addTearDown(tabNotifier.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: Builder(
          builder: (context) {
            final tp = context.watch<ThemeProvider>();
            return MaterialApp(
              theme: tp.buildAppTheme(Brightness.light),
              builder: (_, child) => ThemeTrialBannerHost(child: child!),
              home: ValueListenableBuilder<int>(
                valueListenable: tabNotifier,
                builder: (_, tab, __) => Scaffold(
                  appBar: AppBar(title: Text('页签 $tab')),
                  body: Center(
                    child: Builder(
                      builder: (ctx) => FilledButton(
                        onPressed: () => Navigator.of(ctx).push(
                          MaterialPageRoute<bool>(
                            builder: (_) =>
                                ThemeImportScreen(installed: installed),
                          ),
                        ),
                        child: const Text('去预览'),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('去预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('试用'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('theme-trial-banner')), findsOneWidget);
    expect(find.textContaining('试用中 · 《测试主题》'), findsOneWidget);
    expect(find.text('页签 0'), findsOneWidget);

    // 切换页签后试用横条仍常驻
    tabNotifier.value = 3;
    await tester.pumpAndSettle();
    expect(find.text('页签 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-trial-banner')), findsOneWidget);

    // 点结束恢复原外观
    await tester.tap(find.text('结束'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-trial-banner')), findsNothing);
    expect(provider.hasThemeColors, isFalse);

    // 再次开启试用并点应用
    await tester.tap(find.text('去预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('试用'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('应用'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-trial-banner')), findsNothing);
    expect(provider.hasThemeColors, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('系统文件关联冷热启动、超限与权限错误、新文件覆盖旧读取并自动清理临时副本', (tester) async {
    final incomingDir = Directory(path.join(temp.path, 'incoming-theme'));
    final fileA = File(path.join(incomingDir.path, 'first.sltheme'));
    final fileB = File(path.join(incomingDir.path, 'second.sltheme'));
    await tester.runAsync(() async {
      await incomingDir.create(recursive: true);
      await fileA.writeAsBytes(
        themeArchive(themeFixture()..['name'] = '旧文件主题'),
      );
      await fileB.writeAsBytes(
        themeArchive(themeFixture()..['name'] = '新热启动主题'),
      );
    });

    // 超限错误状态
    final tooLargeReq = ThemeIncomingCoordinator.instance.accept(
      eventId: 'evt-large',
      errorCode: 'theme_too_large',
    );
    await tester.pumpWidget(
      host(
        ThemeImportScreen(
          key: const ValueKey('too-large-screen'),
          incomingRequest: tooLargeReq,
          appVersion: '9.0.0',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('theme_too_large'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    // 权限拒绝状态
    final deniedReq = ThemeIncomingCoordinator.instance.accept(
      eventId: 'evt-denied',
      errorCode: 'permission_denied',
    );
    await tester.pumpWidget(
      host(
        ThemeImportScreen(
          key: const ValueKey('denied-screen'),
          incomingRequest: deniedReq,
          appVersion: '9.0.0',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('检查文件访问权限'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    // 冷启动打开 fileA，随后热启动立刻切入 fileB：旧文件被清理且最终展示新文件
    await tester.runAsync(() async {
      final reqA = ThemeIncomingCoordinator.instance.accept(
        eventId: 'evt-a',
        filePath: fileA.path,
      );
      await tester.pumpWidget(
        host(
          ThemeImportScreen(
            key: const ValueKey('incoming-screen'),
            incomingRequest: reqA,
            appVersion: '9.0.0',
          ),
        ),
      );
      ThemeIncomingCoordinator.instance.accept(
        eventId: 'evt-b',
        filePath: fileB.path,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();
    expect(find.text('新热启动主题'), findsOneWidget);
    expect(find.text('旧文件主题'), findsNothing);
    expect(await tester.runAsync(fileA.exists), isFalse);
    expect(await tester.runAsync(fileB.exists), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ThemeSection 导出当前外观保存文件与壁纸槽位同帧切换', (tester) async {
    final savedPath = path.join(temp.path, 'exported-mixed.sltheme');
    await tester.runAsync(() async {
      final installed =
          await provider.installTheme(_pack(suffix: '7', wallpaper: true));
      await provider.applyInstalledTheme(
        installed,
        {ThemeGroup.colors, ThemeGroup.wallpapers},
      );
    });

    await tester.pumpWidget(
      host(
        Scaffold(
          body: SingleChildScrollView(
            child: ThemeSection(
              saveExportFile: (_, __) async => savedPath,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前外观'), findsOneWidget);
    expect(find.textContaining('测试主题 v1'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('导出当前外观'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('保存到文件'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
      final exportFinished = find.textContaining('已导出 ');
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (exportFinished.evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(find.textContaining('已导出 '), findsOneWidget);
    expect(
        await tester.runAsync(() => File(savedPath).length()), greaterThan(0));

    // 壁纸槽位与页面组件同帧切换，不再淡入淡出。
    await tester.pumpWidget(
      host(
        const Scaffold(body: CustomBackgroundLayer(canvasSize: Size(360, 800))),
      ),
    );
    await settleEmojiQAImages(
      tester,
      tester.element(find.byType(CustomBackgroundLayer)),
      tester.widgetList<Image>(find.byType(Image)).map((image) => image.image),
    );
    await tester.pump();
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
  });

  test('P1.6 完整布局与五张贴纸持久化、按组混搭、局部修改与分组重置互不覆盖', () async {
    final jsonA = themeFixture(id: '00000000-0000-4000-8000-000000000011')
      ..['layout'] = {
        'home': {
          'preset': 'immersive',
          'alignment': 'center',
          'imageHeight': 180,
          'imageWidth': 0.9,
        },
        'campus': {
          'preset': 'compact',
          'alignment': 'start',
          'imageHeight': 120,
          'imageWidth': 1.0,
        },
        'me': {
          'preset': 'standard',
          'alignment': 'end',
          'imageHeight': 150,
          'imageWidth': 0.8,
        },
      };
    for (final mode in ['light', 'dark']) {
      jsonA[mode]['tokens']['primary'] = '#0E7490';
      jsonA[mode]['tokens']['onPrimary'] = '#FFFFFF';
      jsonA[mode]['cardStyle'] = {
        'borderWidth': 1.5,
        'shadow': 'soft',
      };
      jsonA[mode]['decorations'] = {
        'home': {
          'background': {
            'image': 'decorations/bg.png',
            'fit': 'cover',
            'focalX': 0.4,
            'focalY': 0.6,
            'blur': 2,
            'scrim': 0.15,
            'adjustments': {
              'brightness': 10,
              'contrast': 110,
              'saturation': 90,
            },
          },
          'stickers': [
            for (var i = 0; i < 5; i++)
              {
                'image': 'decorations/s$i.png',
                'x': 0.15 + i * 0.15,
                'y': 0.5,
                'width': 0.16,
                'rotation': (i - 2) * 15.0,
              },
          ],
        },
      };
    }
    final packA = PreparedThemePack(
      ThemeManifest.parse(jsonA, appVersion: '9.0.0'),
      {
        'preview/cover.png': themeImage(1080, 2340),
        'decorations/bg.png': themeImage(320, 160),
        for (var i = 0; i < 5; i++) 'decorations/s$i.png': themeImage(48, 48),
      },
    );

    final jsonB = themeFixture(id: '00000000-0000-4000-8000-000000000012')
      ..['layout'] = {
        'home': {
          'preset': 'compact',
          'alignment': 'end',
          'imageHeight': 110,
          'imageWidth': 0.75,
        },
      };
    final packB = PreparedThemePack(
      ThemeManifest.parse(jsonB, appVersion: '9.0.0'),
      {'preview/cover.png': themeImage(1080, 2340)},
    );

    final installedA = await provider.installTheme(packA);
    final installedB = await provider.installTheme(packB);
    await provider.applyInstalledTheme(installedA, ThemeGroup.applicable);
    await provider.setThemeMode(ThemeMode.light);

    // 模拟重启验证所有分组与五张贴纸保留
    final restarted = ThemeProvider(themePackStore: store);
    await restarted.installedThemes();
    expect(
      restarted.appearance.group(ThemeGroup.layout)!['value']['home']['preset'],
      'immersive',
    );
    expect(
      (restarted.appearance.group(ThemeGroup.decoration)!['light']['home']
              ['stickers'] as List)
          .length,
      5,
    );
    expect(
      restarted.appearance.group(ThemeGroup.material)!['light']['cardStyle'],
      {'borderWidth': 1.5, 'shadow': 'soft'},
    );
    restarted.dispose();

    // 仅应用 B 的布局，保留 A 的配色与装饰
    await provider.applyInstalledTheme(installedB, {ThemeGroup.layout});
    expect(
      provider.appearance.group(ThemeGroup.layout)!['value']['home']['preset'],
      'compact',
    );
    expect(
      provider.buildAppTheme(Brightness.light).colorScheme.primary,
      const Color(0xff0e7490),
    );
    expect(
      (provider.appearance.group(ThemeGroup.decoration)!['light']['home']
              ['stickers'] as List)
          .length,
      5,
    );

    // 手动修改透明度不清除 cardStyle
    await provider.setComponentOpacity(0.84);
    expect(
      provider.appearance.group(ThemeGroup.material)!['light']['cardStyle'],
      {'borderWidth': 1.5, 'shadow': 'soft'},
    );

    // 更换页头背景保留贴纸
    final localBg = File(path.join(temp.path, 'new_header.png'));
    await localBg.writeAsBytes(themeImage(200, 100));
    final adoptedBg = await provider.adoptDecorationImage(
      localBg.path,
      ThemeAssetKind.header,
    );
    final currentHomeDeco = Map<String, dynamic>.from(
      provider.appearance.group(ThemeGroup.decoration)!['light']['home'] as Map,
    );
    await provider.updateHeaderDecoration(Brightness.light, 'home', {
      ...currentHomeDeco,
      'background': {
        'image': adoptedBg,
        'fit': 'contain',
        'focalX': 0.5,
        'focalY': 0.5,
        'blur': 0.0,
        'scrim': 0.0,
      },
    });
    expect(
      (provider.appearance.group(ThemeGroup.decoration)!['light']['home']
              ['stickers'] as List)
          .length,
      5,
    );

    // 导出混搭外观包含布局、卡片样式与装饰并可重新解码
    final exported = await provider.exportCurrentAppearance(
      customName: '布局装饰混搭',
      appVersion: '1.0.0',
    );
    final decoded = await ThemePackCodec.decode(exported, appVersion: '9.0.0');
    expect(decoded.manifest.data['layout']['home']['preset'], 'compact');
    expect(decoded.manifest.data['light']['cardStyle']['shadow'], 'soft');
    expect(
      (decoded.manifest.data['light']['decorations']['home']['stickers']
              as List)
          .length,
      5,
    );

    // 重置布局组只影响布局，装饰和卡片材质不受影响
    await provider.resetAppearanceGroup(ThemeGroup.layout);
    expect(provider.appearance.group(ThemeGroup.layout), isNull);
    expect(provider.appearance.group(ThemeGroup.decoration), isNotNull);
    expect(
      provider.appearance.group(ThemeGroup.material)!['light']['cardStyle'],
      isNotNull,
    );
  });

  testWidgets('P1.6 页头三预设、贴纸不遮挡交互与语义、窄屏大字号与分栏边界及卡片描边阴影', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final stickerFile = File(path.join(temp.path, 'sticker.png'));
    final bgFile = File(path.join(temp.path, 'header_bg.png'));
    late String adoptedSticker;
    late String adoptedBg;
    await tester.runAsync(() async {
      await stickerFile.writeAsBytes(themeImage(48, 48));
      await bgFile.writeAsBytes(themeImage(240, 120));
      adoptedSticker = await provider.adoptDecorationImage(
        stickerFile.path,
        ThemeAssetKind.sticker,
      );
      adoptedBg = await provider.adoptDecorationImage(
        bgFile.path,
        ThemeAssetKind.header,
      );
      await provider.updateCardStyle(Brightness.light, {
        'borderWidth': 2.0,
        'shadow': 'medium',
      });
      for (final slot in const ['home', 'campus', 'me']) {
        await provider.updateHeaderDecoration(Brightness.light, slot, {
          'background': {
            'image': adoptedBg,
            'fit': 'cover',
            'focalX': 0.5,
            'focalY': 0.5,
            'blur': 0.0,
            'scrim': 0.1,
          },
          'stickers': [
            for (var i = 0; i < 5; i++)
              {
                'image': adoptedSticker,
                'x': 0.2 + i * 0.15,
                'y': 0.5,
                'width': 0.18,
                'rotation': 12.0 * i,
              },
          ],
        });
      }
    });

    var actionTapped = 0;
    for (final preset in const ['standard', 'compact', 'immersive']) {
      await tester.runAsync(() async {
        for (final slot in const ['home', 'campus', 'me']) {
          await provider.updateHeaderLayout(slot, {
            'preset': preset,
            'alignment': preset == 'compact' ? 'center' : 'start',
            'imageHeight': 132.0,
            'imageWidth': 0.85,
          });
        }
      });

      await tester.pumpWidget(
        host(
          Scaffold(
            body: ListView(
              children: [
                const HomeThemedHeaderBanner(feedModeLabel: '推荐'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: CampusHeader(
                    semester: '2026—2027学年 · 第一学期',
                    date: DateTime(2026, 10, 18),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: AppCardSurface(
                    key: const ValueKey('content-card-sample'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: FilledButton(
                      onPressed: () => actionTapped++,
                      child: const Text('卡片按钮'),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AppCardSurface(
                    key: const ValueKey('excluded-pill-surface'),
                    applyCardStyle: false,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('输入胶囊'),
                  ),
                ),
              ],
            ),
          ),
          scale: 1.5,
        ),
      );
      await settleEmojiQAImages(
        tester,
        tester.element(find.byType(HomeThemedHeaderBanner)),
        tester
            .widgetList<Image>(find.byType(Image))
            .map((image) => image.image),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 沉浸模板在正式页面里只留锚点和叠在 hero 上的标题，hero 图由主壳背景层绘制。
      if (preset == 'immersive') {
        expect(find.byKey(const ValueKey('theme-hero-anchor-home')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('home-themed-header-immersive')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('home-themed-header-info')),
            findsNothing);
        expect(find.byKey(const ValueKey('theme-header-decoration-home')),
            findsNothing);
        await tester.ensureVisible(find.text('卡片按钮'));
        await tester.tap(find.text('卡片按钮'));
        await tester.pump();
        continue;
      }

      // 正式页面装饰区必须包裹 IgnorePointer 与 ExcludeSemantics
      final decoFinder = find.byKey(
        const ValueKey('theme-header-decoration-home'),
      );
      expect(decoFinder, findsOneWidget);
      expect(
        find.ancestor(of: decoFinder, matching: find.byType(IgnorePointer)),
        findsWidgets,
      );
      expect(
        find.ancestor(of: decoFinder, matching: find.byType(ExcludeSemantics)),
        findsWidgets,
      );

      // standard / compact 预设的装饰区在信息区下方
      final infoRect = tester.getRect(
        find.byKey(const ValueKey('home-themed-header-info')),
      );
      final decoRect = tester.getRect(decoFinder);
      expect(infoRect.top, lessThan(decoRect.top));

      // 卡片按钮可正常点击，不被装饰层劫持
      await tester.ensureVisible(find.text('卡片按钮'));
      await tester.tap(find.text('卡片按钮'));
      await tester.pump();
    }
    expect(actionTapped, 3);

    // 验证内容卡片应用 medium 阴影而输入胶囊排除 cardStyle
    await tester.ensureVisible(
      find.byKey(const ValueKey('excluded-pill-surface')),
    );
    await tester.pump();
    final contentOuter = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('content-card-sample')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((contentOuter.decoration as BoxDecoration?)?.boxShadow, isNotEmpty);
    final pillOuter = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('excluded-pill-surface')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(pillOuter.decoration, isNull);

    // 分栏宽度约束下装饰区不越过 380px 分栏边界
    tester.view.physicalSize = const Size(960, 800);
    await tester.binding.setSurfaceSize(const Size(960, 800));
    await tester.pumpWidget(
      host(
        const Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 380,
                child: HomeThemedHeaderBanner(feedModeLabel: '综合'),
              ),
              VerticalDivider(width: 1),
              Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    await settleEmojiQAImages(
      tester,
      tester.element(find.byType(HomeThemedHeaderBanner)),
      tester.widgetList<Image>(find.byType(Image)).map((image) => image.image),
    );
    await tester.pumpAndSettle();
    // 平板分栏内使用完整插画，不再向整屏背景登记手机 hero。
    final splitHeaderRect = tester.getRect(
      find.byKey(const ValueKey('theme-header-decoration-home')),
    );
    expect(splitHeaderRect.right, lessThanOrEqualTo(380.0));
    expect(find.byType(ThemeHeroAnchor), findsNothing);

    // 设置编辑页在 360px + 1.5x 字号下无溢出渲染
    tester.view.physicalSize = const Size(360, 800);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    await tester
        .pumpWidget(host(const ThemeLayoutDecorationScreen(), scale: 1.5));
    await settleEmojiQAImages(
      tester,
      tester.element(find.byType(ThemeLayoutDecorationScreen)),
      tester.widgetList<Image>(find.byType(Image)).map((image) => image.image),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
  });

  testWidgets('主题页头横竖屏和分栏切换保留完整插画与交互，收窄恢复手机沉浸布局',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      for (final mode in Brightness.values) {
        final file = File(path.join(temp.path, 'tablet-header-${mode.name}.png'));
        await file.writeAsBytes(mode == Brightness.light
            ? themeImage(300, 200) : themeImage(500, 185));
        final adopted = await provider.adoptDecorationImage(file.path, ThemeAssetKind.header);
        for (final slot in ['home', 'campus', 'me']) {
          await provider.updateHeaderLayout(slot, {'preset': 'immersive', 'imageHeight': 180.0});
          await provider.updateHeaderDecoration(mode, slot, {
            'background': {'image': adopted, 'fit': 'cover', 'focalY': 0.0},
          });
        }
      }
    });
    var taps = 0;
    for (final brightness in Brightness.values) {
      for (final slot in ['home', 'campus', 'me']) {
        for (final (size, columnWidth) in [
          (const Size(834, 1194), 690.0),
          (const Size(1280, 800), 1000.0),
          (const Size(1280, 800), 380.0),
          (const Size(600, 800), 456.0),
          (const Size(390, 844), 358.0),
        ]) {
          tester.view.physicalSize = size;
          await tester.binding.setSurfaceSize(size);
          final tablet = size.width >= 600;
          await tester.pumpWidget(host(Scaffold(body: Stack(children: [
            const ThemeHeroLayer(),
            Align(alignment: Alignment.topRight, child: SizedBox(
              width: columnWidth,
              child: SingleChildScrollView(child: ThemeHeaderFrame(
                slot: slot,
                defaultBuilder: (_) => const SizedBox(),
                standardInfoBuilder: (_, __) => FilledButton(
                  onPressed: () => taps++, child: const Text('打开页面')),
                compactInfoBuilder: (_, __) => const SizedBox(),
              )),
            )),
          ])), brightness: brightness, scale: 1.5));
          // 先完成明暗主题过渡，再等待新主题选中的图片解码。
          await tester.pumpAndSettle();
          await settleEmojiQAImages(tester,
              tester.element(find.byType(ThemeHeaderFrame)),
              tester.widgetList<Image>(find.byType(Image)).map((image) => image.image));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (tablet) {
            expect(find.byType(ThemeHeroAnchor), findsNothing);
            final decoration = find.byKey(ValueKey('theme-header-decoration-$slot'));
            final rect = tester.getRect(decoration);
            expect(rect.left, greaterThanOrEqualTo(size.width - columnWidth));
            expect(rect.right, lessThanOrEqualTo(size.width));
            expect(rect.width / rect.height,
                closeTo(brightness == Brightness.light ? 1.5 : 500 / 185, 0.01),
                reason: '插画容器沿用原图比例，不留下横屏色带');
            expect(rect.height, lessThanOrEqualTo(300));
            final artwork = tester.widget<Image>(find.descendant(of: decoration, matching: find.byType(Image)).first);
            expect(artwork.fit, BoxFit.contain, reason: '横竖屏均完整呈现角色图');
            final info = tester.getRect(find.byType(FilledButton));
            if (columnWidth >= 600) {
              expect(info.right, lessThan(rect.left));
            } else {
              expect(info.top, greaterThanOrEqualTo(rect.bottom));
            }
          } else {
            expect(find.byType(ThemeHeroAnchor), findsOneWidget);
            expect(find.byKey(ValueKey('theme-header-decoration-$slot')), findsNothing);
          }
          await tester.tap(find.text('打开页面'));
          await tester.pump();
        }
      }
    }
    expect(taps, 30);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
