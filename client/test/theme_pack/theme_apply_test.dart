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
import 'package:shenliyuan/features/theme_pack/theme_import_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_store.dart';
import 'package:shenliyuan/features/theme_pack/theme_section.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_palette.dart';
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
  Future<void> clearStaging() async {}
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
    bool navigation = false}) {
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
      'style': 'normal',
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
    final theme = await provider.installTheme(_pack());
    preferences.fail = true;
    await expectLater(provider.applyInstalledTheme(theme, {ThemeGroup.colors}),
        throwsA(isA<FileSystemException>()));
    expect(provider.hasThemeColors, isFalse);
    expect(preferences.getString(ThemeProvider.previousAppearanceKey), isNull);
    preferences.fail = false;
    await provider.applyInstalledTheme(theme, {ThemeGroup.colors});
    expect(provider.hasThemeColors, isTrue);
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
    expect(find.text('打开导入'), findsOneWidget);
    expect((await tester.runAsync(provider.installedThemes))!.length, 1);
    await tester.tap(find.text('撤销'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    expect(provider.hasThemeColors, isFalse);
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
          const Scaffold(body: SingleChildScrollView(child: ThemeSection())),
          brightness: brightness,
          scale: 1.5));
      await tester.pumpAndSettle();
      expect(find.text('恢复上一个外观'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    });
  }
}
