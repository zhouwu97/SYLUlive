import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/theme_pack/launcher_icon_service.dart';
import 'package:shenliyuan/features/theme_pack/theme_appearance.dart';
import 'package:shenliyuan/features/theme_pack/theme_font_registry.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_store.dart';
import 'package:shenliyuan/features/theme_pack/theme_widget_palette.dart';
import 'package:shenliyuan/models/home_widget_config.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_palette.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';

import '../helpers/load_test_fonts.dart';
import 'theme_pack_test.dart' show themeArchive, themeFixture;

Uint8List _opaquePng(int size, {int r = 20, int g = 124, int b = 114}) {
  final canvas = img.Image(width: size, height: size);
  img.fill(canvas, color: img.ColorRgba8(r, g, b, 255));
  return Uint8List.fromList(img.encodePng(canvas));
}

Uint8List _fakeSfntMissingRequiredTables() {
  // 头部与表偏移合法，但只有单个未知表，缺少 cmap/head/hhea/maxp/name 与轮廓表。
  final bytes = Uint8List(32);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0x00010000);
  data.setUint16(4, 1);
  bytes.setRange(12, 16, ascii.encode('DUMMY'.substring(0, 4)));
  data.setUint32(20, 28);
  data.setUint32(24, 4);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late MemoryPreferencesStore prefs;
  late Uint8List validFontBytes;
  final widgetCalls = <MethodCall>[];
  final iconCalls = <MethodCall>[];
  String pinShortcutStatus = 'requested';
  bool settingsOpened = false;

  setUpAll(() async {
    await loadTestFonts();
    final fontData = await rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf');
    validFontBytes = fontData.buffer.asUint8List(
      fontData.offsetInBytes,
      fontData.lengthInBytes,
    );
  });

  setUp(() async {
    ThemeFontRegistry.debugResetForTesting();
    widgetCalls.clear();
    iconCalls.clear();
    pinShortcutStatus = 'requested';
    settingsOpened = false;
    temp = await Directory.systemTemp.createTemp('sltheme-p15-');
    prefs = MemoryPreferencesStore();
    AppPreferencesStore.setCustomInstance(prefs);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('shenliyuan/widget'),
      (call) async {
        widgetCalls.add(call);
        return true;
      },
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      LauncherIconService.channel,
      (call) async {
        iconCalls.add(call);
        switch (call.method) {
          case 'current':
            return <String, dynamic>{
              'activeId': prefs.getString(LauncherIconService.desiredIdKey) ?? 'default',
              'desiredId': prefs.getString(LauncherIconService.desiredIdKey) ?? 'default',
              'themed': prefs.getBool(LauncherIconService.desiredThemedKey) ?? false,
              'sdkInt': 34,
              'pinShortcutSupported': true,
            };
          case 'setDesired':
            return null;
          case 'requestPinThemeShortcut':
            return <String, dynamic>{
              'status': pinShortcutStatus,
            };
          case 'openShortcutPermissionSettings':
            settingsOpened = true;
            return true;
          default:
            return null;
        }
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('shenliyuan/widget'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LauncherIconService.channel, null);
    AppPreferencesStore.setCustomInstance(null);
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<ThemeProvider> newProvider() async {
    final p = ThemeProvider(
      loadOnStart: false,
      themePackStore: ThemePackStore(
        directory: Directory(path.join(temp.path, 'themes')),
      ),
    );
    await p.loadThemeForTesting();
    return p;
  }

  test('自定义字体：试加载损坏报错、应用切换家族名与回退链、冷启动首帧预加载及恢复默认', () async {
    // 1. 头部合法但缺少核心表的损坏字体在解码边界直接报 theme_font_invalid
    final badManifest = themeFixture(id: '00000000-0000-4000-8000-000000000051')
      ..['font'] = {
        'name': '残缺字体',
        'regular': 'fonts/broken.ttf',
        'license': 'OFL-1.1',
      };
    await expectLater(
      ThemePackCodec.decode(
        themeArchive(badManifest, files: {
          'fonts/broken.ttf': _fakeSfntMissingRequiredTables(),
        }),
        appVersion: '9.0.0',
      ),
      throwsA(
        isA<ThemePackError>()
            .having((e) => e.code, 'code', 'theme_font_invalid')
            .having((e) => e.field, 'field', 'fonts/broken.ttf'),
      ),
    );

    // 2. 合法字体导入并应用后，ThemeData.fontFamily 为 theme_font_<id>_<version>，回退首项为 NotoSansCJKsc
    const fontThemeId = '00000000-0000-4000-8000-000000000052';
    final goodManifest = themeFixture(id: fontThemeId, version: 3)
      ..['font'] = {
        'name': '测试文楷',
        'regular': 'fonts/regular.otf',
        'bold': 'fonts/bold.otf',
        'license': 'OFL-1.1',
      };
    final pack = await ThemePackCodec.decode(
      themeArchive(
        goodManifest,
        files: {
          'fonts/regular.otf': validFontBytes,
          'fonts/bold.otf': validFontBytes,
        },
      ),
      appVersion: '9.0.0',
    );

    final provider = await newProvider();
    addTearDown(provider.dispose);
    final installed = await provider.installTheme(pack);
    await provider.applyInstalledTheme(
      installed,
      {ThemeGroup.colors, ThemeGroup.font},
    );

    const expectedFamily = 'theme_font_${fontThemeId}_3';
    final lightTheme = provider.buildAppTheme(Brightness.light);
    expect(lightTheme.textTheme.bodyMedium?.fontFamily, expectedFamily);
    expect(lightTheme.textTheme.bodyMedium?.fontFamilyFallback?.first, 'NotoSansCJKsc');
    expect(lightTheme.appBarTheme.titleTextStyle?.fontFamily, expectedFamily);
    // 等宽样式保持不变
    const monoStyle = TextStyle(fontFamily: 'monospace');
    expect(monoStyle.fontFamily, 'monospace');

    // 3. 模拟进程重启与 app_bootstrap 首帧预加载：runApp 前已完成注册，首帧即用主题字体
    ThemeFontRegistry.debugResetForTesting();
    await ThemeFontRegistry.preloadFromPreferences(
      prefs,
      appearanceKey: ThemeProvider.appearanceKey,
    );
    final restarted = await newProvider();
    addTearDown(restarted.dispose);
    expect(
      restarted.buildAppTheme(Brightness.dark).textTheme.bodyLarge?.fontFamily,
      expectedFamily,
    );

    // 4. 恢复默认外观后回到 NotoSansCJKsc
    await restarted.restoreManualAppearance();
    expect(
      restarted.buildAppTheme(Brightness.light).textTheme.bodyMedium?.fontFamily,
      'NotoSansCJKsc',
    );
    expect(AppTheme.defaultFontFallback.first, 'NotoSansCJKsc');
  });

  test('桌面小部件：契约 3.1 颜色映射、毛玻璃 0.82 不透明度、应用与恢复同步及主题课程色板', () async {
    // 1. 默认 palette 与自定义 palette 逐项核对契约 3.1 映射
    final defaultLight = AppPalette.defaults(Brightness.light);
    final defaultPayload =
        ThemeWidgetPalette.buildPayload(const ThemeAppearance.empty());
    expect(defaultPayload['light'], {
      'background': ThemeWidgetPalette.formatArgbHex(defaultLight.card.withAlpha(0xFF)),
      'primaryText': ThemeWidgetPalette.formatArgbHex(defaultLight.textPrimary),
      'secondaryText': ThemeWidgetPalette.formatArgbHex(defaultLight.textSecondary),
      'mutedText': ThemeWidgetPalette.formatArgbHex(defaultLight.textTertiary),
      'accent': ThemeWidgetPalette.formatArgbHex(defaultLight.primary),
      'divider': ThemeWidgetPalette.formatArgbHex(defaultLight.divider),
    });

    const seaThemeId = '00000000-0000-4000-8000-000000000053';
    final customManifest = themeFixture(id: seaThemeId);
    final lightTokens =
        (customManifest['light'] as Map<String, dynamic>)['tokens'] as Map<String, dynamic>;
    lightTokens['card'] = '#F5F9FF';
    lightTokens['textPrimary'] = '#102030';
    lightTokens['textSecondary'] = '#405060';
    lightTokens['textTertiary'] = '#708090';
    lightTokens['primary'] = '#2F7FD8';
    lightTokens['divider'] = '#D0E0F0';
    (customManifest['light'] as Map<String, dynamic>)['coursePalette'] = [
      '#1166AA',
      '#2288BB',
      '#3399CC',
      '#44AADD',
      '#55BBEE',
    ];

    // 预置小部件课程数据与原手动主题
    await prefs.setString(HomeWidgetPreferenceKeys.courseTheme, 'campusBlue');
    await prefs.setString(HomeWidgetPreferenceKeys.examTheme, 'dark');
    await prefs.setString(
      'widget_course_data',
      jsonEncode({
        'schema_version': 2,
        'updated_at': '2026-11-18T00:00:00.000Z',
        'title': '沈理院课表',
        'semester_start': '2026-09-01',
        'academic_year': '2026-2027',
        'semester': 1,
        'courses': [
          {
            'name': '高等数学',
            'course_code': 'MATH101',
            'weekday': 1,
            'start_section': 1,
            'end_section': 2,
            'weeks': [1, 2, 3],
            'location': 'A101',
            'teacher': '张老师',
            'color': '#448AFF',
          },
        ],
      }),
    );

    final provider = await newProvider();
    addTearDown(provider.dispose);
    final pack = await ThemePackCodec.decode(
      themeArchive(customManifest),
      appVersion: '9.0.0',
    );
    final installed = await provider.installTheme(pack);
    widgetCalls.clear();

    await provider.applyInstalledTheme(
      installed,
      {ThemeGroup.colors, ThemeGroup.widgets},
    );

    expect(prefs.getString(HomeWidgetPreferenceKeys.courseTheme), 'appTheme');
    expect(prefs.getString(HomeWidgetPreferenceKeys.examTheme), 'appTheme');
    final rawPalette = prefs.getString(HomeWidgetPreferenceKeys.appPalette);
    expect(rawPalette, isNotNull);
    final savedPalette = jsonDecode(rawPalette!) as Map<String, dynamic>;
    expect(savedPalette['light'], {
      'background': '#FFF5F9FF',
      'primaryText': '#FF102030',
      'secondaryText': '#FF405060',
      'mutedText': '#FF708090',
      'accent': '#FF2F7FD8',
      'divider': '#FFD0E0F0',
    });

    // 2. 毛玻璃不透明度：开启为 209 (0.82)，关闭为 255 (1.0)
    final glassResolved = HomeWidgetThemePalette.resolve(
      HomeWidgetTheme.appTheme,
      systemBrightness: Brightness.light,
      appPaletteJson: rawPalette,
      frostedGlass: true,
    );
    final solidResolved = HomeWidgetThemePalette.resolve(
      HomeWidgetTheme.appTheme,
      systemBrightness: Brightness.light,
      appPaletteJson: rawPalette,
      frostedGlass: false,
    );
    expect((glassResolved.background.a * 255.0).round(), 209);
    expect((solidResolved.background.a * 255.0).round(), 255);

    // 3. 课程颜色使用主题色板，且触发了原生 updateWidget 通道
    final expectedCourseColor = ThemeWidgetPalette.resolveCourseHex(
      '高等数学',
      palette: const [
        Color(0xFF1166AA),
        Color(0xFF2288BB),
        Color(0xFF3399CC),
        Color(0xFF44AADD),
        Color(0xFF55BBEE),
      ],
      courseCode: 'MATH101',
      location: 'A101',
    );
    final syncedCourseData =
        jsonDecode(prefs.getString('widget_course_data')!) as Map<String, dynamic>;
    expect(
      ((syncedCourseData['courses'] as List).single as Map)['color'],
      expectedCourseColor,
    );
    expect(
      widgetCalls.where((c) => c.method == 'updateWidget'),
      isNotEmpty,
    );

    // 4. 恢复默认外观后还原手动小部件主题、重算默认色板并再次触发更新
    widgetCalls.clear();
    await provider.restoreManualAppearance();
    expect(prefs.getString(HomeWidgetPreferenceKeys.courseTheme), 'campusBlue');
    expect(prefs.getString(HomeWidgetPreferenceKeys.examTheme), 'dark');
    final resetPalette =
        jsonDecode(prefs.getString(HomeWidgetPreferenceKeys.appPalette)!)
            as Map<String, dynamic>;
    expect(
      (resetPalette['light'] as Map)['background'],
      ThemeWidgetPalette.formatArgbHex(defaultLight.card.withAlpha(0xFF)),
    );
    expect(
      widgetCalls.where((c) => c.method == 'updateWidget'),
      isNotEmpty,
    );
  });

  test('桌面图标：未勾选不调通道、勾选保留当前 themed 调用 setDesired、恢复默认不改动图标', () async {
    await prefs.setBool(LauncherIconService.desiredThemedKey, true);
    final manifest = themeFixture(id: '00000000-0000-4000-8000-000000000054')
      ..['launcherIcon'] = {
        'builtin': 'sea',
        'custom': 'icons/launcher.png',
      };
    final pack = await ThemePackCodec.decode(
      themeArchive(
        manifest,
        files: {'icons/launcher.png': _opaquePng(512)},
      ),
      appVersion: '9.0.0',
    );
    final provider = await newProvider();
    addTearDown(provider.dispose);
    final installed = await provider.installTheme(pack);

    // 1. 未勾选 launcherIcon：不调用 app_icon 通道
    iconCalls.clear();
    await provider.applyInstalledTheme(installed, {ThemeGroup.colors});
    expect(iconCalls, isEmpty);

    // 2. 勾选 launcherIcon：调用 setDesired('sea', true)，保留当前 themed 设置
    await provider.applyInstalledTheme(
      installed,
      {ThemeGroup.colors, ThemeGroup.launcherIcon},
    );
    expect(iconCalls.map((c) => c.method), ['setDesired']);
    expect(iconCalls.single.arguments, {
      'id': 'sea',
      'themed': true,
    });

    // 3. 恢复默认外观：不调用 app_icon 通道
    iconCalls.clear();
    await provider.restoreManualAppearance();
    expect(iconCalls, isEmpty);
  });

  testWidgets('桌面图标设置页：展示自定义快捷方式入口并处理 HyperOS 权限引导弹窗', (tester) async {
    pinShortcutStatus = 'permission_required';
    final manifest = themeFixture(id: '00000000-0000-4000-8000-000000000055')
      ..['launcherIcon'] = {
        'builtin': 'default',
        'custom': 'icons/launcher.png',
      };

    late ThemeProvider provider;
    await tester.runAsync(() async {
      final pack = await ThemePackCodec.decode(
        themeArchive(
          manifest,
          files: {'icons/launcher.png': _opaquePng(512)},
        ),
        appVersion: '9.0.0',
      );
      provider = await newProvider();
      final installed = await provider.installTheme(pack);
      await provider.applyInstalledTheme(
        installed,
        {ThemeGroup.colors, ThemeGroup.launcherIcon},
      );
    });
    addTearDown(() => provider.dispose());

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light).copyWith(
            platform: TargetPlatform.android,
          ),
          home: const LauncherIconSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('跟随系统主题色'), findsOneWidget);
    expect(find.text('用主题图标添加桌面快捷方式'), findsOneWidget);

    await tester.tap(find.text('用主题图标添加桌面快捷方式'));
    await tester.pumpAndSettle();

    expect(find.byType(AppAlertDialog), findsOneWidget);
    expect(find.text('需要桌面快捷方式权限'), findsOneWidget);

    await tester.tap(find.text('前往权限设置'));
    await tester.pumpAndSettle();
    expect(settingsOpened, isTrue);
  });
}
