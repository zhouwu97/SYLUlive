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

  test('超大字号为 2×2 使用双条紧凑布局并让 4×2 双列内容居中', () {
    final registry = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/HomeWidgetRegistry.kt',
    );
    expect(registry, contains('NativeHomeWidgetFontSize.EXTRA_LARGE'));
    expect(registry, contains('R.layout.widget_course_4x2_extra_large'));
    expect(registry, contains('R.layout.widget_exam_4x2_extra_large'));
    expect(registry, contains('R.layout.widget_course_item_extra_large'));
    expect(registry, contains('R.layout.widget_exam_item_extra_large'));
    expect(
      registry,
      contains('R.layout.widget_course_item_extra_large_compact'),
    );
    expect(
      registry,
      contains('R.layout.widget_exam_item_extra_large_compact'),
    );

    for (final path in const [
      'android/app/src/main/res/layout/widget_course_item_extra_large_compact.xml',
      'android/app/src/main/res/layout/widget_exam_item_extra_large_compact.xml',
    ]) {
      final layout = source(path);
      expect(layout, contains('android:layout_height="68dp"'));
    }

    for (final path in const [
      'android/app/src/main/res/layout/widget_course_4x2_extra_large.xml',
      'android/app/src/main/res/layout/widget_exam_4x2_extra_large.xml',
    ]) {
      final layout = source(path);
      expect(layout, contains('<GridView'));
      expect(layout, contains('android:numColumns="2"'));
      expect(layout, contains('android:paddingTop="28dp"'));
    }
  });

  test('课表标题和日期的 RelativeLayout 约束不能形成双向依赖', () {
    for (final path in const [
      'android/app/src/main/res/layout/widget_course_2x2.xml',
      'android/app/src/main/res/layout/widget_course_4x2.xml',
    ]) {
      final layout = source(path);
      expect(layout, contains('android:layout_toStartOf="@id/tv_widget_date"'));
      expect(layout,
          isNot(contains('android:layout_toEndOf="@id/tv_widget_title"')));
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

  test('WidgetDateChangeReceiver 注册系统日期/时间变更广播', () {
    final manifest = source('android/app/src/main/AndroidManifest.xml');
    expect(manifest, contains('.WidgetDateChangeReceiver'));
    expect(manifest, contains('android.intent.action.DATE_CHANGED'));
    expect(manifest, contains('android.intent.action.TIME_SET'));
    expect(manifest, contains('android.intent.action.TIMEZONE_CHANGED'));

    final receiver = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/WidgetDateChangeReceiver.kt',
    );
    expect(receiver, contains('HomeWidgetRegistry.refreshAll(context)'));
  });

  test('CourseDataReader 原生实现 Schema v2 全量课表动态计算与过期节次过滤', () {
    final reader = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/CourseData.kt',
    );
    expect(reader, contains('parseV2'));
    expect(reader, contains('parseV1'));
    expect(reader, contains('semester_start'));
    expect(reader, contains('currentWeekday'));
    expect(reader, contains('academicWeek'));
  });

  test('MainActivity onResume 触发桌面小组件全量刷新', () {
    final mainActivity = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/MainActivity.kt',
    );
    expect(mainActivity, contains('HomeWidgetRegistry.refreshAll(this)'));
  });

  test('列表适配器使用与背景相同的主题快照并通过 URI 失效旧缓存', () {
    final renderer = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/HomeWidgetRenderer.kt',
    );
    expect(renderer, contains('EXTRA_RESOLVED_THEME'));
    expect(renderer, contains('EXTRA_FONT_SIZE'));
    expect(renderer, contains('appendQueryParameter'));
    expect(renderer, contains('theme.resolvedTheme.storageName'));

    for (final path in const [
      'android/app/src/main/kotlin/com/example/shenliyuan/CourseWidgetService.kt',
      'android/app/src/main/kotlin/com/example/shenliyuan/ExamWidgetService.kt',
    ]) {
      final service = source(path);
      expect(service, contains('EXTRA_RESOLVED_THEME'));
      expect(service, contains('EXTRA_FONT_SIZE'));
      final dataSetChanged =
          service.split('override fun onDataSetChanged()')[1];
      expect(dataSetChanged, isNot(contains('HomeWidgetAppearanceStore.read')));
    }
  });

  test('Flutter 刷新参数先在原生侧原子同步外观，再渲染桌面组件', () {
    final service = source('lib/services/home_widget_service.dart');
    final mainActivity = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/MainActivity.kt',
    );
    final appearanceStore = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/HomeWidgetThemeConfig.kt',
    );
    for (final key in const ['theme', 'title', 'font_size']) {
      expect(service, contains("'\${kind.storageName}_$key'"));
      expect(mainActivity, contains('course_$key'));
      expect(mainActivity, contains('exam_$key'));
    }
    final updateHandler = mainActivity
        .split('"updateWidget" ->')[1]
        .split('"startPeriodicUpdate" ->')[0];
    expect(updateHandler.indexOf('HomeWidgetAppearanceStore.synchronize'),
        lessThan(updateHandler.indexOf('refreshWidgets()')));
    expect(appearanceStore, contains('editor.commit()'));
  });

  test('系统深浅色变化时 MainActivity 主动刷新跟随系统的小组件', () {
    final mainActivity = source(
      'android/app/src/main/kotlin/com/example/shenliyuan/MainActivity.kt',
    );
    expect(mainActivity, contains('override fun onConfigurationChanged'));
    expect(mainActivity, contains('Configuration.UI_MODE_NIGHT_MASK'));
    expect(mainActivity, contains('HomeWidgetRegistry.refreshAll(this)'));
  });
}
