import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/home_widget_config.dart';
import 'package:shenliyuan/services/home_widget_service.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
