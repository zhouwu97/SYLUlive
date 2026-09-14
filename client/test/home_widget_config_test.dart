import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/home_widget_config.dart';
import 'package:shenliyuan/models/exam_schedule.dart';
import 'package:shenliyuan/services/home_widget_service.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';
import 'package:shenliyuan/services/exam_schedule_repository.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('桌面小组件字号', () {
    test('未知存储值和空值默认标准', () {
      expect(HomeWidgetFontSize.fromStorage(null), HomeWidgetFontSize.standard);
      expect(
        HomeWidgetFontSize.fromStorage('bad'),
        HomeWidgetFontSize.standard,
      );
    });

    test('四档字号保存读取正确且课表与考试互不污染', () async {
      AppPreferencesStore.setMockInitialValues({});

      await HomeWidgetService.updateAppearance(
        const HomeWidgetAppearance(
          kind: HomeWidgetKind.course,
          theme: HomeWidgetTheme.light,
          title: '今日课表',
          fontSize: HomeWidgetFontSize.extraLarge,
        ),
      );
      await HomeWidgetService.updateAppearance(
        const HomeWidgetAppearance(
          kind: HomeWidgetKind.exam,
          theme: HomeWidgetTheme.dark,
          title: '考试日程',
          fontSize: HomeWidgetFontSize.small,
        ),
      );

      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.course)).fontSize,
        HomeWidgetFontSize.extraLarge,
      );
      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.exam)).fontSize,
        HomeWidgetFontSize.small,
      );
    });

    test('连续外观更新按调用顺序保存，最后一次选择稳定生效', () async {
      AppPreferencesStore.setMockInitialValues({});
      final firstRefreshStarted = Completer<void>();
      final releaseFirstRefresh = Completer<void>();
      var refreshCount = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('shenliyuan/widget'),
        (call) async {
          if (call.method != 'updateWidget') return null;
          refreshCount += 1;
          if (refreshCount == 1) {
            firstRefreshStarted.complete();
            await releaseFirstRefresh.future;
          }
          return null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('shenliyuan/widget'),
          null,
        ),
      );

      final first = HomeWidgetService.updateAppearance(
        const HomeWidgetAppearance(
          kind: HomeWidgetKind.course,
          theme: HomeWidgetTheme.light,
          title: '今日课表',
        ),
      );
      await firstRefreshStarted.future;
      final second = HomeWidgetService.updateAppearance(
        const HomeWidgetAppearance(
          kind: HomeWidgetKind.course,
          theme: HomeWidgetTheme.dark,
          title: '今日课表',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(refreshCount, 1);
      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.course)).theme,
        HomeWidgetTheme.light,
      );

      releaseFirstRefresh.complete();
      await Future.wait([first, second]);

      expect(refreshCount, 2);
      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.course)).theme,
        HomeWidgetTheme.dark,
      );
    });

    test('copyWith 修改其他外观字段不会丢失字号', () {
      const appearance = HomeWidgetAppearance(
        kind: HomeWidgetKind.course,
        theme: HomeWidgetTheme.light,
        title: '课表',
        fontSize: HomeWidgetFontSize.large,
      );

      expect(appearance.copyWith(theme: HomeWidgetTheme.dark).fontSize,
          HomeWidgetFontSize.large);
      expect(
          appearance.copyWith(title: '新标题').fontSize, HomeWidgetFontSize.large);
      expect(
        appearance.copyWith(fontSize: HomeWidgetFontSize.small).theme,
        HomeWidgetTheme.light,
      );
      expect(
        appearance.copyWith(fontSize: HomeWidgetFontSize.small).title,
        '课表',
      );
    });

    test('Typography resolver 只改变字号角色，不改变尺寸档位语义', () {
      final compact = HomeWidgetTypography.resolve(
        HomeWidgetSize.size2x2,
        HomeWidgetFontSize.standard,
      );
      final detailed = HomeWidgetTypography.resolve(
        HomeWidgetSize.size4x2,
        HomeWidgetFontSize.large,
      );

      expect(compact.title, 13);
      expect(compact.primary, 11);
      expect(detailed.title, 15);
      expect(detailed.primary, 13);
      expect(detailed.tertiary, 9);

      final compactExtraLarge = HomeWidgetTypography.resolve(
        HomeWidgetSize.size2x2,
        HomeWidgetFontSize.extraLarge,
      );
      final detailedExtraLarge = HomeWidgetTypography.resolve(
        HomeWidgetSize.size4x2,
        HomeWidgetFontSize.extraLarge,
      );
      expect(compactExtraLarge.primary, 16);
      expect(compactExtraLarge.tertiary, 13);
      expect(detailedExtraLarge.primary, 18);
      expect(detailedExtraLarge.secondary, 14);
      expect(
        HomeWidgetContentPolicy.previewItemCount(
          HomeWidgetSize.size2x2,
          HomeWidgetFontSize.extraLarge,
        ),
        2,
      );
      expect(
        HomeWidgetContentPolicy.previewItemCount(
          HomeWidgetSize.size4x2,
          HomeWidgetFontSize.extraLarge,
        ),
        2,
      );
    });
  });

  group('桌面小组件外观迁移', () {
    test('旧白色文字迁移为两套独立深色主题和标题', () async {
      AppPreferencesStore.setMockInitialValues({
        HomeWidgetPreferenceKeys.legacyTextColor: '#FFFFFF',
        HomeWidgetPreferenceKeys.legacyTitle: '我的校园',
      });

      await HomeWidgetService.migrateLegacyAppearance();
      final course =
          await HomeWidgetService.getAppearance(HomeWidgetKind.course);
      final exam = await HomeWidgetService.getAppearance(HomeWidgetKind.exam);

      expect(course.theme, HomeWidgetTheme.dark);
      expect(exam.theme, HomeWidgetTheme.dark);
      expect(course.title, '我的校园');
      expect(exam.title, '我的校园');
      expect(course.fontSize, HomeWidgetFontSize.standard);
      expect(exam.fontSize, HomeWidgetFontSize.standard);
    });

    test('没有旧配置的新安装默认跟随系统', () async {
      AppPreferencesStore.setMockInitialValues({});

      await HomeWidgetService.migrateLegacyAppearance();

      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.course)).theme,
        HomeWidgetTheme.system,
      );
      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.exam)).theme,
        HomeWidgetTheme.system,
      );
    });

    test('修改课表主题不会修改考试主题', () async {
      AppPreferencesStore.setMockInitialValues({});
      await HomeWidgetService.migrateLegacyAppearance();

      await HomeWidgetService.updateAppearance(
        const HomeWidgetAppearance(
          kind: HomeWidgetKind.course,
          theme: HomeWidgetTheme.campusBlue,
          title: '今日课表',
        ),
      );

      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.course)).theme,
        HomeWidgetTheme.campusBlue,
      );
      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.exam)).theme,
        HomeWidgetTheme.system,
      );
    });

    test('修改考试主题不会修改课表主题', () async {
      AppPreferencesStore.setMockInitialValues({});
      await HomeWidgetService.migrateLegacyAppearance();

      await HomeWidgetService.updateAppearance(
        const HomeWidgetAppearance(
          kind: HomeWidgetKind.exam,
          theme: HomeWidgetTheme.dark,
          title: '考试倒计时',
        ),
      );

      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.course)).theme,
        HomeWidgetTheme.system,
      );
      expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.exam)).theme,
        HomeWidgetTheme.dark,
      );
    });
  });

  test('light、dark、campusBlue 主题配色解析正确', () {
    final light = HomeWidgetThemePalette.resolve(
      HomeWidgetTheme.light,
      systemBrightness: Brightness.dark,
    );
    final dark = HomeWidgetThemePalette.resolve(
      HomeWidgetTheme.dark,
      systemBrightness: Brightness.light,
    );
    final blue = HomeWidgetThemePalette.resolve(
      HomeWidgetTheme.campusBlue,
      systemBrightness: Brightness.light,
    );

    expect(light.primaryText, const Color(0xFF111827));
    expect(light.secondaryText, const Color(0xFF4B5563));
    expect(dark.background, const Color(0xF21F2937));
    expect(dark.primaryText, const Color(0xFFF9FAFB));
    expect(blue.background, const Color(0xF2EFF6FF));
    expect(blue.accent, const Color(0xFF3B82F6));
  });

  test('小组件未知或损坏 schema 安全降级为空数据', () async {
    AppPreferencesStore.setMockInitialValues({
      'widget_course_data': jsonEncode({
        'schema_version': 99,
        'courses': [
          {'name': '不应展示', 'time': '08:00-09:00'},
        ],
      }),
      'widget_exam_data': '{invalid-json',
    });

    final course = await HomeWidgetService.getPreviewData(
      HomeWidgetKind.course,
    );
    final exam = await HomeWidgetService.getPreviewData(HomeWidgetKind.exam);

    expect(course.items, isEmpty);
    expect(exam.items, isEmpty);
  });

  test('小组件课表 schema v2 全量数据动态计算当天课表', () async {
    final now = DateTime.now();
    final weekday = now.weekday;
    final semesterStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: (weekday - 1)));
    final semesterStartStr =
        '${semesterStart.year}-${semesterStart.month.toString().padLeft(2, '0')}-${semesterStart.day.toString().padLeft(2, '0')}';

    AppPreferencesStore.setMockInitialValues({
      'widget_course_data': jsonEncode({
        'schema_version': 2,
        'semester_start': semesterStartStr,
        'academic_year': '2026-2027',
        'semester': 1,
        'courses': [
          {
            'name': '今日课程',
            'weekday': weekday,
            'start_section': 1,
            'end_section': 2,
            'weeks': [1, 2, 3],
            'location': '综A101',
            'teacher': '王老师',
            'color': '#3B82F6',
          },
          {
            'name': '非今日课程',
            'weekday': weekday == 7 ? 1 : weekday + 1,
            'start_section': 3,
            'end_section': 4,
            'weeks': [1, 2, 3],
            'location': '综B202',
            'teacher': '李老师',
            'color': '#10B981',
          },
        ],
      }),
    });

    final preview =
        await HomeWidgetService.getPreviewData(HomeWidgetKind.course);
    expect(preview.items, hasLength(1));
    expect(preview.items.single.title, '今日课程');
    expect(preview.items.single.primaryDetail, '08:00-09:40');
    expect(preview.items.single.secondaryDetail, '综A101 · 王老师');
  });

  test('小组件考试 schema v0 顶层数组仍可读取', () async {
    AppPreferencesStore.setMockInitialValues({
      'widget_exam_data': jsonEncode([
        {
          'name': '兼容考试',
          'date': '2026-08-30',
          'time': '08:00-10:00',
          'location': '综合楼A101',
        },
      ]),
    });

    final preview = await HomeWidgetService.getPreviewData(
      HomeWidgetKind.exam,
    );

    expect(preview.items, hasLength(1));
    expect(preview.items.single.title, '兼容考试');
  });

  group('桌面小组件考试数据账号隔离与退出清理', () {
    setUp(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('shenliyuan/widget'),
        (call) async => null,
      );
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('shenliyuan/widget'),
        null,
      );
    });

    test('A账号拉取考试并同步 -> 退出登录 -> 小组件数据与本地考试被清除 (A->logout)', () async {
      AppPreferencesStore.setMockInitialValues({});
      final coordinator = AccountSessionCleanupCoordinator();
      coordinator.register('exam_cleanup', () async {
        await HomeWidgetService.clearExamData();
        await ExamScheduleRepository().clear();
      });

      // 1. 用户 A 同步考试
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await HomeWidgetService.syncExamData([
        HomeWidgetExamEntry(
          name: '高等数学A',
          startTime: tomorrow,
          endTime: tomorrow.add(const Duration(hours: 2)),
          location: '综A101',
        ),
      ]);

      final previewBefore =
          await HomeWidgetService.getPreviewData(HomeWidgetKind.exam);
      expect(previewBefore.items, hasLength(1));
      expect(previewBefore.items.single.title, '高等数学A');

      // 2. 模拟登出：触发账号会话清理
      await coordinator.closeCurrentSession();

      // 3. 验证小组件数据已清空
      final previewAfter =
          await HomeWidgetService.getPreviewData(HomeWidgetKind.exam);
      expect(previewAfter.items, isEmpty);
    });

    test(
        'A账号拉取考试 -> 退出登录 -> B账号登录且未拉取考试 -> 小组件绝不展示A账号考试 (A->logout->B)',
        () async {
      AppPreferencesStore.setMockInitialValues({});
      final coordinator = AccountSessionCleanupCoordinator();
      coordinator.register('exam_cleanup', () async {
        await HomeWidgetService.clearExamData();
        await ExamScheduleRepository().clear();
      });

      // 1. A 账号登录并同步考试与本地仓库
      final futureDate = DateTime.now().add(const Duration(days: 2));
      await HomeWidgetService.syncExamData([
        HomeWidgetExamEntry(
          name: '大学物理B',
          startTime: futureDate,
          endTime: futureDate.add(const Duration(hours: 2)),
          location: '理教302',
        ),
      ]);
      await ExamScheduleRepository().save([
        ExamModel(
          name: '大学物理B',
          startTime: futureDate,
          endTime: futureDate.add(const Duration(hours: 2)),
          location: '理教302',
          semester: '2026-2027-01',
        ),
      ]);

      expect(
          (await HomeWidgetService.getPreviewData(HomeWidgetKind.exam)).items,
          hasLength(1));
      expect((await ExamScheduleRepository().load()), hasLength(1));

      // 2. A 登出
      await coordinator.closeCurrentSession();

      // 3. B 账号登录（此时 B 尚未拉取考试）
      // 桌面小组件由 B 打开/查看
      final previewB =
          await HomeWidgetService.getPreviewData(HomeWidgetKind.exam);
      final localExamsB = await ExamScheduleRepository().load();

      expect(previewB.items, isEmpty, reason: 'B 账号绝不能看到 A 账号的考试小组件');
      expect(localExamsB, isEmpty, reason: 'B 账号本地考试安排应为空');
    });

    test('clearExamDataForIdentity 按身份精准清理，不同身份互不误伤', () async {
      AppPreferencesStore.setMockInitialValues({});
      const identityA = AcademicIdentityKey(
        appUserId: '1',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: '20230001',
      );
      const identityB = AcademicIdentityKey(
        appUserId: '2',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: '20230002',
      );
      final prefs = await AppPreferencesStore.getInstance();
      await AcademicConnectionStore(identityA, prefs).setConnected(true);
      await AcademicConnectionStore(identityB, prefs).setConnected(true);

      final futureDate = DateTime.now().add(const Duration(days: 1));
      await HomeWidgetService.syncExamData(
        [
          HomeWidgetExamEntry(
            name: '数据结构',
            startTime: futureDate,
            endTime: futureDate.add(const Duration(hours: 2)),
            location: '计机楼201',
          ),
        ],
        identity: identityA,
      );

      expect(
          (await HomeWidgetService.getPreviewData(HomeWidgetKind.exam)).items,
          hasLength(1));

      // 尝试用 B 的身份清理 A 的小组件，应当不生效
      await HomeWidgetService.clearExamDataForIdentity(identityB);
      expect(
          (await HomeWidgetService.getPreviewData(HomeWidgetKind.exam)).items,
          hasLength(1));

      // 用 A 的身份清理，成功清理
      await HomeWidgetService.clearExamDataForIdentity(identityA);
      expect(
          (await HomeWidgetService.getPreviewData(HomeWidgetKind.exam)).items,
          isEmpty);
    });
  });
}
