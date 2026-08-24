import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('Registry 注册并刷新四种独立组件', () {
    final registry = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/HomeWidgetRegistry.kt',
    );
    for (final variant in const [
      'COURSE_2X2',
      'COURSE_4X2',
      'EXAM_2X2',
      'EXAM_4X2',
    ]) {
      expect(registry, contains(variant));
    }
    expect(registry, contains('for (variant in variants)'));
    expect(
        registry, contains('HomeWidgetRenderer.build(context, id, variant)'));
  });

  test('2×2 和 4×2 使用不同布局及不同数量限制', () {
    final registry = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/HomeWidgetRegistry.kt',
    );
    expect(registry, contains('R.layout.widget_course_2x2'));
    expect(registry, contains('R.layout.widget_course_4x2'));
    expect(registry, contains('R.layout.widget_exam_2x2'));
    expect(registry, contains('R.layout.widget_exam_4x2'));
    expect(registry, contains('R.layout.widget_course_item_compact'));
    expect(registry, contains('R.layout.widget_course_item_detailed'));
  });

  test('课表标题和日期的 RelativeLayout 约束不能形成双向依赖', () {
    for (final path in const [
      'android/app/src/main/res/layout/widget_course_2x2.xml',
      'android/app/src/main/res/layout/widget_course_4x2.xml',
    ]) {
      final layout = source(path);
      expect(layout, contains('android:layout_toStartOf="@id/tv_widget_date"'));
      expect(layout, isNot(contains('android:layout_toEndOf="@id/tv_widget_title"')));
    }
  });

  test('空状态颜色由主题 mutedTextColor 统一控制', () {
    final renderer = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/HomeWidgetRenderer.kt',
    );
    expect(
      renderer,
      contains('views.setTextColor(R.id.empty_view, theme.mutedTextColor)'),
    );
    expect(
      source('android/app/src/main/res/layout/widget_course_2x2.xml'),
      contains('android:textColor="#9CA3AF"'),
    );
    expect(
      source('android/app/src/main/res/layout/widget_exam_2x2.xml'),
      contains('android:textColor="#9CA3AF"'),
    );
  });

  test('考试倒计时在原生读取时跨天重算', () {
    final data = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/ExamData.kt',
    );
    expect(data, contains('diffDays == 0L -> "今天"'));
    expect(data, contains('diffDays == 1L -> "明天"'));
    expect(data, contains('diffDays == 2L -> "后天"'));
    expect(data, contains('diffDays < 0L -> "已结束"'));
  });

  test('课表透明度和高度只属于课表显示，不再属于桌面小组件', () {
    final settings = source('lib/screens/course_schedule_settings_screen.dart');
    final schedule = source('lib/screens/course_schedule_screen.dart');
    expect(settings, contains("title: '课表显示'"));
    expect(settings, contains("title: '课程块透明度'"));
    expect(settings, contains("title: '每节课高度'"));
    expect(settings, contains("title: '管理桌面小组件'"));
    expect(settings, isNot(contains('桌面小组件外观')));
    expect(schedule, isNot(contains('_showOpacitySheet')));
    expect(schedule, contains('_scheduleCardOpacity'));
    expect(schedule, contains('_scheduleSlotHeight'));
  });
}
