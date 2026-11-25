import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/course_schedule_screen.dart';
import 'package:shenliyuan/screens/course_schedule_settings_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/theme/app_palette.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_gate.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/features/campus_data/storage/schedule_cache_store.dart';
import 'package:shenliyuan/models/course_term.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_store.dart';

import 'helpers/load_test_fonts.dart';
import 'theme_pack/theme_pack_test.dart' show themeFixture, themeImage;

class _FailingDisplayPreferences extends MemoryPreferencesStore {
  bool fail = true;

  @override
  Future<bool> setString(String key, String value) async =>
      fail && key == 'schedule_text_color'
          ? false
          : await super.setString(key, value);
}

/// 无延迟的内存快照存储。不能用 YieldingPersonalSnapshotStore：
/// 它的 `Future.delayed(Duration.zero)` 在 testWidgets 的 FakeAsync 里、
/// 首次 pump 之前永远不会完成，会导致 setup await 挂死。
class _MemorySnapshotStore implements AccountScopedSnapshotStore {
  PersonalSnapshot? _snapshot;
  Completer<bool>? pendingWrite;
  int writes = 0;

  @override
  final String accountFingerprint = 'course-test-account';

  @override
  Future<void> clearUser() async {
    _snapshot = null;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteType(PersonalDataType type) async {
    if (_snapshot?.type == type) _snapshot = null;
  }

  @override
  Future<PersonalSnapshot?> read({
    required PersonalDataType type,
    required String sourceSystem,
    required String sourceAccountId,
  }) async {
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.type != type) return null;
    return PersonalSnapshot(
      appUserFingerprint: snapshot.appUserFingerprint,
      sourceAccountFingerprint: snapshot.sourceAccountFingerprint,
      type: snapshot.type,
      schemaVersion: snapshot.schemaVersion,
      encryptionVersion: snapshot.encryptionVersion,
      fetchedAt: snapshot.fetchedAt,
      expiresAt: snapshot.expiresAt,
      contentHash: snapshot.contentHash,
      payload: Map<String, dynamic>.from(snapshot.payload),
    );
  }

  @override
  Future<void> write({
    required PersonalDataType type,
    required int schemaVersion,
    required String sourceSystem,
    required String sourceAccountId,
    required Map<String, dynamic> payload,
    DateTime? fetchedAt,
    DateTime? expiresAt,
  }) async {
    writes++;
    final pending = pendingWrite;
    if (pending != null && !await pending.future) throw StateError('测试保存失败');
    _snapshot = PersonalSnapshot(
      appUserFingerprint: accountFingerprint,
      sourceAccountFingerprint: 'test-source',
      type: type,
      schemaVersion: schemaVersion,
      encryptionVersion: 1,
      fetchedAt: fetchedAt ?? DateTime.now().toUtc(),
      expiresAt: expiresAt,
      contentHash: 'test-content-hash',
      payload: Map<String, dynamic>.from(payload),
    );
  }
}

class _CourseAuthProvider extends ChangeNotifier implements AuthProvider {
  _CourseAuthProvider({required this.client});

  final Dio client;

  @override
  User? get user =>
      User(id: 1, studentId: 's1', nickname: '测试用户', createdAt: DateTime(2026));

  @override
  bool get isLoggedIn => true;

  @override
  int get sessionGeneration => 0;

  @override
  int get accountSessionEpoch => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BoundEduProvider extends EduProvider {
  _BoundEduProvider() : super(Dio());

  @override
  bool get isBound => true;

  @override
  bool get isStatusLoaded => true;

  @override
  void setUserId(String userId) {}

  @override
  Future<void> ensureStatusLoaded() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 从表头里找到「学期标题  M/D - M/D」的周日期文本。
String? _weekHeaderText(WidgetTester tester) {
  final datePattern = RegExp(r'\d{1,2}/\d{1,2} - \d{1,2}/\d{1,2}');
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    // 页头日期区间用 en dash 排版，这里统一成连字符再比较。
    final data = (text.data ?? '').replaceAll('–', '-');
    if (datePattern.hasMatch(data)) return data;
  }
  return null;
}

DateTime _mondayOf(DateTime d) {
  return DateTime(d.year, d.month, d.day)
      .subtract(Duration(days: d.weekday - 1));
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() {
    AcademicPersistenceRegistry.set('1', enabled: true);
  });

  tearDown(() {
    AcademicPersistenceRegistry.clear('1');
    AppPreferencesStore.setCustomInstance(null);
  });

  testWidgets('应用主题同步课表颜色选择，手动调整、重新应用和撤销保持真实颜色', (tester) async {
    const widgets = MethodChannel('shenliyuan/widget');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(widgets, (call) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(widgets, null));
    final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('schedule-theme-sync-'));
    addTearDown(() => directory!.delete(recursive: true));
    final theme = ThemeProvider(
        loadOnStart: false,
        themePackStore: ThemePackStore(directory: directory));
    final page = await _pumpCourse(tester,
        appearanceProvider: theme,
        initialPreferences: const {
          'schedule_text_color': 'dark',
          'schedule_course_color': 'blue'
        });
    late InstalledTheme installed;
    await tester.runAsync(() async {
      await theme.loadThemeForTesting();
      final manifest = themeFixture();
      for (final mode in ['light', 'dark']) {
        manifest[mode]['tokens']['courseCardText'] = '#6D4C9A';
        manifest[mode]['coursePalette'] = List.filled(5, '#D2D4FF');
      }
      installed = await theme.installTheme(PreparedThemePack(
          ThemeManifest.parse(manifest, appVersion: '9.0.0'),
          {'preview/cover.png': themeImage(1080, 2340)}));
      await theme.applyInstalledTheme(installed, ThemeGroup.defaultApply);
    });
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('高等数学')).style!.color,
        const Color(0xFF6D4C9A));
    expect(_courseDecoration(tester, '高等数学').color, const Color(0xFFD2D4FF));
    await _openDisplaySettings(tester);
    expect(find.text('默认，跟随当前主题'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('课程块颜色'), 100,
        scrollable: _settingsScrollable());
    expect(find.text('默认，按课程配色'), findsOneWidget);
    await tester.runAsync(() => _selectDisplayColor(tester, '课表文字颜色', '橙色'));
    expect(find.text('橙色'), findsOneWidget);
    expect(
        (await AppPreferencesStore.getInstance())
            .getString('schedule_text_color'),
        'dark');
    final savedAppearance = (await AppPreferencesStore.getInstance())
        .getString(ThemeProvider.appearanceKey);
    await tester.runAsync(() => theme.startTrial(
        installed: installed, groups: ThemeGroup.defaultApply));
    await tester.pumpAndSettle();
    expect(find.text('默认，跟随当前主题'), findsOneWidget);
    await tester.runAsync(theme.endTrial);
    await tester.pumpAndSettle();
    expect(find.text('橙色'), findsOneWidget);
    expect(
        (await AppPreferencesStore.getInstance())
            .getString(ThemeProvider.appearanceKey),
        savedAppearance);
    await tester.runAsync(
        () => theme.applyInstalledTheme(installed, ThemeGroup.defaultApply));
    await tester.pumpAndSettle();
    expect(find.text('默认，跟随当前主题'), findsOneWidget);
    await tester.runAsync(theme.restorePreviousAppearance);
    await tester.pumpAndSettle();
    expect(find.text('橙色'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('高等数学')).style!.color,
        ScheduleColorOption.orange.color);
    expect(tester.takeException(), isNull);
    await _disposeCourse(tester, page);
  });

  testWidgets('课表字号和颜色可保存、重新进入并恢复原默认显示', (tester) async {
    var page = await _pumpCourse(tester);
    final defaultSize = tester.widget<Text>(find.text('高等数学')).style!.fontSize!;
    final defaultColor = _courseDecoration(tester, '高等数学').color;
    final defaultTextColor =
        tester.widget<Text>(find.text('高等数学')).style!.color;

    await _openDisplaySettings(tester);
    expect(find.text('100%（默认）'), findsOneWidget);
    final fontTile = find
        .ancestor(
          of: find.text('课表字体大小'),
          matching: find.byType(Column),
        )
        .first;
    final fontSlider =
        find.descendant(of: fontTile, matching: find.byType(Slider));
    final sliderRect = tester.getRect(fontSlider);
    await tester.tapAt(
        Offset(sliderRect.left + sliderRect.width * .75, sliderRect.center.dy));
    await tester.pumpAndSettle();
    await _selectDisplayColor(tester, '课表文字颜色', '深色');
    await _selectDisplayColor(tester, '课程块颜色', '蓝色');
    await _captureDisplay(tester, 'settings-custom');

    final prefs = await AppPreferencesStore.getInstance();
    final saved = <String, Object>{
      'schedule_font_scale': prefs.getDouble('schedule_font_scale')!,
      'schedule_text_color': prefs.getString('schedule_text_color')!,
      'schedule_course_color': prefs.getString('schedule_course_color')!,
    };
    expect(saved['schedule_font_scale'], greaterThan(1));
    expect(saved['schedule_text_color'], 'dark');
    expect(saved['schedule_course_color'], 'blue');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('高等数学')).style!.fontSize,
        closeTo(defaultSize * (saved['schedule_font_scale']! as double), .001));
    expect(tester.widget<Text>(find.text('高等数学')).style!.color,
        ScheduleColorOption.dark.color);
    expect(_courseDecoration(tester, '高等数学').color,
        ScheduleColorOption.blue.color);
    await _captureDisplay(tester, 'course-custom');
    await _disposeCourse(tester, page);

    page = await _pumpCourse(tester, initialPreferences: saved);
    expect(tester.widget<Text>(find.text('高等数学')).style!.color,
        ScheduleColorOption.dark.color);
    expect(tester.widget<Text>(find.text('高等数学')).style!.fontSize,
        closeTo(defaultSize * (saved['schedule_font_scale']! as double), .001));
    await _openDisplaySettings(tester);
    await tester.scrollUntilVisible(find.text('恢复课表显示默认值'), 220,
        scrollable: _settingsScrollable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复课表显示默认值'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('高等数学')).style!.fontSize, defaultSize);
    expect(
        tester.widget<Text>(find.text('高等数学')).style!.color, defaultTextColor);
    expect(_courseDecoration(tester, '高等数学').color, defaultColor);
    expect(
        (await AppPreferencesStore.getInstance())
            .getDouble('schedule_font_scale'),
        1);
    await _captureDisplay(tester, 'course-restored');
    expect(tester.takeException(), isNull);
    await _disposeCourse(tester, page);
  });

  testWidgets('颜色保存失败显示原选择并可重试，取消选择不保存', (tester) async {
    final page = await _pumpCourse(tester);
    final prefs = _FailingDisplayPreferences();
    AppPreferencesStore.setCustomInstance(prefs);
    await _openDisplaySettings(tester);
    await _selectDisplayColor(tester, '课表文字颜色', '深色');
    expect(find.text('操作失败，请重试'), findsOneWidget);
    expect(find.text('默认，跟随当前主题'), findsOneWidget);
    expect(prefs.getString('schedule_text_color'), isNull);
    prefs.fail = false;
    await _selectDisplayColor(tester, '课表文字颜色', '深色');
    expect(prefs.getString('schedule_text_color'), 'dark');
    await tester.tap(find.text('课表文字颜色'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 80));
    await tester.pumpAndSettle();
    expect(prefs.getString('schedule_text_color'), 'dark');
    expect(tester.takeException(), isNull);
    await _disposeCourse(tester, page);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('最大课表字号与系统大字在单节、非本周、冲突课程无溢出 $mode', (tester) async {
      final page = await _pumpCourse(
        tester,
        physicalSize: const Size(360, 800),
        themeMode: mode,
        textScaleFactor: 1.3,
        initialPreferences: const {
          'slot_height': 55.0,
          'schedule_font_scale': 1.5,
          'schedule_text_color': 'dark',
          'schedule_course_color': 'blue',
        },
        seededCourses: [
          for (final entry in [
            (1, 1, [1]),
            (2, 2, [2]),
            (3, 3, [1]),
            (4, 3, [1])
          ])
            {
              'id': entry.$1,
              'name': '课程${entry.$1}',
              'location': '综合楼 A224',
              'weekday': entry.$2,
              'start_section': 1,
              'end_section': 1,
              'weeks': entry.$3,
            },
        ],
      );
      expect(_courseDecoration(tester, '课程1').color,
          ScheduleColorOption.blue.color);
      expect(_courseDecoration(tester, '课程2').color, const Color(0xFF9E9E9E));
      expect(
          _courseDecoration(tester, '2门课程冲突').color, const Color(0xFFE65100));
      expect(tester.takeException(), isNull);
      await _captureDisplay(tester, 'large-${mode.name}');
      await _openDisplaySettings(tester);
      await _captureDisplay(tester, 'settings-large-${mode.name}');
      expect(tester.takeException(), isNull);
      await _disposeCourse(tester, page);
    });
  }

  testWidgets('手动添加显示保存状态，失败提示留在弹窗中，重试后立即关闭并显示课程', (tester) async {
    final store = _MemorySnapshotStore();
    final page = await _pumpCourse(tester, memoryStore: store);
    await page.scheduleProvider.applyFetchedCourses([
      {
        'name': '原有课程',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1, 2],
      }
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('添加自定义课程'));
    await tester.tap(find.text('添加自定义课程'));
    // 设置页在等待弹窗关闭时持续显示进度，弹窗内只推进必要的动画帧。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('添加'));
    await tester.pump();
    expect(find.text('请输入课程名称'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '手动补课');
    store.pendingWrite = Completer<bool>();
    final writesBefore = store.writes;
    await tester.tap(find.text('添加'));
    await tester.pump();
    expect(find.text('正在保存…'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '正在保存…'))
            .onPressed,
        isNull);
    expect(store.writes, writesBefore + 1);
    store.pendingWrite!.complete(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('保存失败，请重试'), findsOneWidget);
    expect(page.scheduleProvider.courses.any((c) => c.name == '手动补课'), isFalse);
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '手动补课');
    store.pendingWrite = null;
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(page.scheduleProvider.courses.where((c) => c.name == '手动补课'),
        hasLength(1));
    expect(tester.takeException(), isNull);
    await _disposeCourse(tester, page);
  });

  for (final customColor in [null, Colors.indigo]) {
    testWidgets('本周课程恢复白字并支持主题覆盖 custom=$customColor', (tester) async {
      final palette = AppPalette.defaults(Brightness.light);
      final page = await _pumpCourse(
        tester,
        lightTheme: AppTheme.build(
          brightness: Brightness.light,
          palette: customColor == null
              ? null
              : palette.copyWith(courseCardText: customColor),
        ),
        seededCourses: [
          {
            'id': 1,
            'name': '高等数学',
            'teacher': '张老师',
            'location': 'A101',
            'weekday': 1,
            'start_section': 1,
            'end_section': 2,
            'weeks': [1],
          },
          {
            'id': 2,
            'name': '后期开课',
            'weekday': 2,
            'start_section': 1,
            'end_section': 2,
            'weeks': [2],
          },
        ],
      );

      final activeColor = customColor ?? Colors.white;
      for (final label in ['高等数学', 'A101']) {
        expect(tester.widget<Text>(find.text(label)).style!.color, activeColor);
      }
      expect(tester.widget<Text>(find.text('张老师')).style!.color,
          activeColor.withValues(alpha: 0.6));
      expect(tester.widget<Text>(find.text('后期开课')).style!.color,
          palette.textPrimary);
      expect(find.text('后期'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _disposeCourse(tester, page);
    });
  }

  testWidgets('课表中部横滑切周', (tester) async {
    final page = await _pumpCourse(tester);

    final before = _weekHeaderText(tester);
    expect(before, isNotNull);

    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();

    expect(_weekHeaderText(tester), isNot(before));

    await _disposeCourse(tester, page);
  });

  testWidgets('课表底部 120px 区域横滑仍可切周', (tester) async {
    final page = await _pumpCourse(tester);

    final before = _weekHeaderText(tester);
    expect(before, isNotNull);

    // 屏幕高度 800，底部 120px 即 y >= 680。旧行为在这里拒绝周横滑。
    await tester.dragFrom(const Offset(220, 760), const Offset(-250, 0));
    await tester.pumpAndSettle();

    expect(_weekHeaderText(tester), isNot(before));

    await _disposeCourse(tester, page);
  });

  testWidgets('未设置开学周时不展示课程且不能横向切周', (tester) async {
    final page = await _pumpCourse(
      tester,
      configureSemesterStart: false,
    );

    expect(find.text('未设置开学周'), findsNothing);
    expect(
      find.byKey(const ValueKey('schedule-semester-start-required')),
      findsOneWidget,
    );
    expect(find.byType(PageView), findsNothing);

    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('schedule-semester-start-required')),
      findsOneWidget,
    );

    await _disposeCourse(tester, page);
  });

  testWidgets('课表拖动时保持跟手，松手后才同步周次', (tester) async {
    final page = await _pumpCourse(tester);
    final before = _weekHeaderText(tester);
    expect(before, isNotNull);

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    final startPage = controller.page!;
    final gesture = await tester.startGesture(const Offset(220, 400));
    await gesture.moveBy(const Offset(-25, 0));
    await gesture.moveBy(const Offset(-25, 0));
    await gesture.moveBy(const Offset(-25, 0));
    await gesture.moveBy(const Offset(-25, 0));
    await gesture.moveBy(const Offset(-25, 0));
    await gesture.moveBy(const Offset(-25, 0));
    await gesture.moveBy(const Offset(-25, 0));
    await gesture.moveBy(const Offset(-25, 0));
    await gesture.moveBy(const Offset(-25, 0));
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump();

    final pageWhileHolding = controller.page!;
    expect(pageWhileHolding, isNot(closeTo(startPage, 0.001)));
    expect(_weekHeaderText(tester), before);

    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.page, closeTo(pageWhileHolding, 0.001));
    expect(_weekHeaderText(tester), before);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_weekHeaderText(tester), isNot(before));

    await _disposeCourse(tester, page);
  });

  // ====== 有限分页边界 ======

  String weekRange(DateTime monday) =>
      '${monday.month}/${monday.day} - ${monday.add(const Duration(days: 6)).month}/${monday.add(const Duration(days: 6)).day}';

  // 当前日期早于开学 → 锚定到第 1 周
  testWidgets('开学日在未来时 page0 就是第1周', (tester) async {
    final futureMonday =
        _mondayOf(DateTime.now()).add(const Duration(days: 21));
    final page = await _pumpCourse(tester, semesterStart: futureMonday);

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller.page, closeTo(0, 0.001));
    expect(find.text('第 1 周'), findsOneWidget);
    expect(_weekHeaderText(tester), contains(weekRange(futureMonday)));

    await _disposeCourse(tester, page);
  });

  testWidgets('第1周向前(右滑)不能进入第0周', (tester) async {
    final futureMonday =
        _mondayOf(DateTime.now()).add(const Duration(days: 21));
    final page = await _pumpCourse(tester, semesterStart: futureMonday);
    expect(find.text('第 1 周'), findsOneWidget);
    final before = _weekHeaderText(tester);

    await tester.dragFrom(const Offset(220, 400), const Offset(250, 0));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller.page, closeTo(0, 0.001));
    expect(find.text('第 1 周'), findsOneWidget);
    expect(_weekHeaderText(tester), before);

    await _disposeCourse(tester, page);
  });

  testWidgets('第1周向后(左滑)进入第2周', (tester) async {
    final futureMonday =
        _mondayOf(DateTime.now()).add(const Duration(days: 21));
    final page = await _pumpCourse(tester, semesterStart: futureMonday);

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller.page, closeTo(0, 0.001));

    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();

    expect(controller.page, closeTo(1, 0.001));
    expect(find.text('第 2 周'), findsOneWidget);
    final week2 = futureMonday.add(const Duration(days: 7));
    expect(_weekHeaderText(tester), contains(weekRange(week2)));

    await _disposeCourse(tester, page);
  });

  testWidgets('第2周向前(右滑)返回第1周', (tester) async {
    final futureMonday =
        _mondayOf(DateTime.now()).add(const Duration(days: 21));
    final page = await _pumpCourse(tester, semesterStart: futureMonday);

    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 2 周'), findsOneWidget);

    await tester.dragFrom(const Offset(220, 400), const Offset(250, 0));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller.page, closeTo(0, 0.001));
    expect(find.text('第 1 周'), findsOneWidget);

    await _disposeCourse(tester, page);
  });

  testWidgets('最后一周不能再向后(左滑)', (tester) async {
    const maxWeek = 20; // CourseTerm 默认值
    final lastWeekMonday = _mondayOf(DateTime.now());
    final semesterStart =
        lastWeekMonday.subtract(const Duration(days: (maxWeek - 1) * 7));
    final page = await _pumpCourse(tester, semesterStart: semesterStart);

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller.page, closeTo(maxWeek - 1, 0.001));
    expect(find.text('第 $maxWeek 周'), findsOneWidget);
    final before = _weekHeaderText(tester);

    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();

    expect(controller.page, closeTo(maxWeek - 1, 0.001));
    expect(find.text('第 $maxWeek 周'), findsOneWidget);
    expect(_weekHeaderText(tester), before);

    await _disposeCourse(tester, page);
  });

  testWidgets('重设开学周后分页器日期与页码同步重置', (tester) async {
    final original = _mondayOf(DateTime.now()).add(const Duration(days: 21));
    final page = await _pumpCourse(tester, semesterStart: original);
    expect(find.text('第 1 周'), findsOneWidget);

    // 先滑到第2周，制造非初始状态
    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 2 周'), findsOneWidget);

    final newStart = _mondayOf(DateTime.now()).add(const Duration(days: 42));
    await page.scheduleProvider.setSemesterStart(newStart);
    await tester.pumpAndSettle();

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller.page, closeTo(0, 0.001));
    expect(find.text('第 1 周'), findsOneWidget);
    expect(_weekHeaderText(tester), contains(weekRange(newStart)));

    await _disposeCourse(tester, page);
  });

  testWidgets('拖动时星期表头与课程网格保持同一水平位移', (tester) async {
    final page = await _pumpCourse(tester);

    final headerBefore = tester.getCenter(find.text('一')).dx;
    final cardBefore = tester.getCenter(find.text('高等数学')).dx;

    final gesture = await tester.startGesture(const Offset(220, 400));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();

    final headerDuring = tester.getCenter(find.text('一')).dx;
    final cardDuring = tester.getCenter(find.text('高等数学')).dx;

    await gesture.up();
    await tester.pumpAndSettle();

    expect(headerDuring - headerBefore, closeTo(cardDuring - cardBefore, 0.5));

    await _disposeCourse(tester, page);
  });

  testWidgets('研究生稀疏及超过本科范围的行序沿用本科节次时间轴', (tester) async {
    final page = await _pumpCourse(
      tester,
      seededCourses: [
        <String, dynamic>{
          'id': 1,
          'course_code': 'G-1',
          'name': '研究生上午课',
          'weekday': 1,
          'start_section': 3,
          'end_section': 3,
          'period_order': 2,
          'period_label': '上午3',
          'weeks': <int>[1, 2, 3],
        },
        <String, dynamic>{
          'id': 2,
          'course_code': 'G-2',
          'name': '研究生晚间课',
          'weekday': 2,
          'start_section': 15,
          'end_section': 15,
          'period_order': 14,
          'period_label': '下午8',
          'weeks': <int>[1, 2, 3],
        },
      ],
    );

    expect(find.text('1\n08:00\n08:45'), findsOneWidget);
    expect(find.text('3\n10:00\n10:45'), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
    expect(find.text('上午3'), findsNothing);
    expect(find.text('下午8'), findsNothing);
    expect(find.textContaining('时段'), findsNothing);

    await _disposeCourse(tester, page);
  });

  testWidgets('研究生双小节课程跨两行展示并完整占用节次', (tester) async {
    final page = await _pumpCourse(
      tester,
      initialPreferences: const <String, Object>{'slot_height': 120.0},
      seededCourses: [
        <String, dynamic>{
          'id': 11,
          'course_code': 'G-11',
          'name': '新时代中国特色社会主义理论与实践研究4班',
          'teacher': '张慧雪',
          'location': '综合楼 A224',
          'weekday': 1,
          'start_section': 3,
          'end_section': 4,
          'period_order': 2,
          'period_label': '上午3-4',
          'period_labels': <String>['上午3', '上午4'],
          'weeks': <int>[1, 2, 3],
        },
        <String, dynamic>{
          'id': 12,
          'course_code': 'G-12',
          'name': '不应叠加的后续课程',
          'weekday': 1,
          'start_section': 4,
          'end_section': 4,
          'period_order': 3,
          'period_label': '上午4',
          'weeks': <int>[2, 3],
        },
      ],
    );

    expect(find.text('3\n10:00\n10:45'), findsOneWidget);
    expect(find.text('4\n10:55\n11:40'), findsOneWidget);
    expect(find.text('不应叠加的后续课程'), findsNothing);
    expect(find.text('张慧雪'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('11_1_3'))).height,
      120 * 2 - 2,
    );
    expect(tester.takeException(), isNull);

    await _disposeCourse(tester, page);
  });

  testWidgets('研究生双小节课程在深色大字号手机视口无溢出', (tester) async {
    final page = await _pumpCourse(
      tester,
      physicalSize: const Size(360, 800),
      themeMode: ThemeMode.dark,
      textScaleFactor: 1.3,
      seededCourses: [
        <String, dynamic>{
          'id': 21,
          'course_code': 'G-21',
          'name': '新时代中国特色社会主义理论与实践研究4班',
          'teacher': '张慧雪',
          'location': '综合楼 A224',
          'weekday': 1,
          'start_section': 3,
          'end_section': 4,
          'period_order': 2,
          'period_label': '上午3-4',
          'period_labels': <String>['上午3', '上午4'],
          'weeks': <int>[1, 2, 3],
        },
      ],
    );

    expect(find.text('3\n10:00\n10:45'), findsOneWidget);
    expect(find.text('4\n10:55\n11:40'), findsOneWidget);
    expect(find.byKey(const ValueKey('21_1_3')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _disposeCourse(tester, page);
  });
}

Finder _settingsScrollable() => find
    .descendant(
      of: find.byType(CourseScheduleSettingsScreen),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _openDisplaySettings(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_horiz_rounded));
  await tester.pumpAndSettle();
  await tester.tap(find.text('课表设置'));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('课表字体大小'), 250,
      scrollable: _settingsScrollable());
  await tester.pumpAndSettle();
}

Future<void> _selectDisplayColor(
  WidgetTester tester,
  String title,
  String color,
) async {
  await tester.scrollUntilVisible(find.text(title), 100,
      scrollable: _settingsScrollable());
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
  await _captureDisplay(
      tester, title == '课表文字颜色' ? 'text-color-picker' : 'course-color-picker');
  await tester.tap(find.text(color).last);
  await tester.pumpAndSettle();
}

BoxDecoration _courseDecoration(WidgetTester tester, String name) => tester
    .widget<AppCardSurface>(find
        .ancestor(
          of: find.text(name),
          matching: find.byType(AppCardSurface),
        )
        .first)
    .decoration! as BoxDecoration;

Future<void> _captureDisplay(WidgetTester tester, String name) async {
  final directory = Platform.environment['SCHEDULE_DISPLAY_EVIDENCE'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('course-display-render')));
    final image = await render.toImage(pixelRatio: 1);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Future<_CourseTestPage> _pumpCourse(
  WidgetTester tester, {
  bool configureSemesterStart = true,
  DateTime? semesterStart,
  List<Map<String, dynamic>>? seededCourses,
  Size physicalSize = const Size(400, 800),
  ThemeMode themeMode = ThemeMode.light,
  ThemeData? lightTheme,
  double textScaleFactor = 1,
  Map<String, Object> initialPreferences = const <String, Object>{},
  _MemorySnapshotStore? memoryStore,
  ThemeProvider? appearanceProvider,
}) async {
  AppPreferencesStore.setMockInitialValues(initialPreferences);
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  // 课表页会查询课程提醒后台保活状态；不 mock 的话平台通道 Future 永不完成，
  // 其 2s timeout 计时器会残留在测试结束时触发断言。
  const reminderChannel = MethodChannel('shenliyuan/course_reminders');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(reminderChannel, (call) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(reminderChannel, null);
  });

  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: <dynamic>[]),
        );
      },
    ),
  );

  // 通过内存快照商店预置一门课程，让课表走「本地缓存优先」路径渲染周分页器。
  final snapshotStore = memoryStore ?? _MemorySnapshotStore();
  final scheduleProvider = CourseScheduleProvider(dio, (_) => snapshotStore);
  scheduleProvider.syncSessionContext('1', 'edu-1');
  // 测试字体 Ahem 下每个字符都是全宽，过长的学期标题会让表头行溢出；
  // 注入短标题保持 400x800 真实手机宽度下无布局误差。
  await scheduleProvider.switchTerm(
    const CourseTerm(
      id: '2026_3',
      year: '2026',
      semester: 3,
      title: '26 第一学期',
      isCurrent: true,
    ),
    loadCache: false,
  );
  final store = ScheduleCacheStore(
    appUserId: '1',
    sourceAccountId: 'edu-1',
    snapshotStore: snapshotStore,
  );
  await store.writeCourses(
    year: scheduleProvider.currentTerm.year,
    semester: scheduleProvider.currentTerm.semester,
    courses: seededCourses ??
        [
          <String, dynamic>{
            'id': 1,
            'course_code': 'C1',
            'name': '高等数学',
            'teacher': '张老师',
            'location': 'A101',
            'color': '#6366F1',
            'weekday': 1,
            'start_section': 1,
            'end_section': 2,
            'weeks': <int>[
              for (var w = 1; w <= 20; w++) w,
            ],
          },
        ],
  );
  if (configureSemesterStart) {
    await scheduleProvider.setSemesterStart(semesterStart ?? DateTime.now());
  }

  final auth = _CourseAuthProvider(client: dio);
  final eduProvider = _BoundEduProvider();
  final themeProvider = appearanceProvider ?? ThemeProvider(loadOnStart: false);

  final widget = MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<EduProvider>.value(value: eduProvider),
      ChangeNotifierProvider<CourseScheduleProvider>.value(
          value: scheduleProvider),
      ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
    ],
    child: Builder(
        builder: (context) => MaterialApp(
              themeMode: themeMode,
              theme: lightTheme ??
                  (appearanceProvider == null
                      ? ThemeData(
                          brightness: Brightness.light,
                          fontFamily: 'NotoSansCJKsc')
                      : context
                          .watch<ThemeProvider>()
                          .buildAppTheme(Brightness.light)),
              darkTheme: ThemeData(
                  brightness: Brightness.dark, fontFamily: 'NotoSansCJKsc'),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(textScaleFactor),
                ),
                child: child!,
              ),
              home: const CourseScheduleScreen(),
            )),
  );
  await tester.pumpWidget(RepaintBoundary(
    key: const ValueKey('course-display-render'),
    child: widget,
  ));
  await tester.pumpAndSettle();

  return _CourseTestPage(
    auth: auth,
    eduProvider: eduProvider,
    scheduleProvider: scheduleProvider,
    themeProvider: themeProvider,
  );
}

Future<void> _disposeCourse(WidgetTester tester, _CourseTestPage page) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  page.auth.dispose();
  page.eduProvider.dispose();
  page.scheduleProvider.dispose();
  page.themeProvider.dispose();
}

class _CourseTestPage {
  const _CourseTestPage({
    required this.auth,
    required this.eduProvider,
    required this.scheduleProvider,
    required this.themeProvider,
  });

  final _CourseAuthProvider auth;
  final _BoundEduProvider eduProvider;
  final CourseScheduleProvider scheduleProvider;
  final ThemeProvider themeProvider;
}
