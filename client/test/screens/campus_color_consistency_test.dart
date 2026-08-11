import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/campus_article.dart';
import 'package:shenliyuan/screens/campus_article_list_screen.dart';
import 'package:shenliyuan/screens/course_schedule_settings_screen.dart';
import 'package:shenliyuan/services/campus_article_service.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/campus/campus_theme.dart';

class _EmptyArticleService extends CampusArticleService {
  _EmptyArticleService() : super(Dio());

  @override
  Future<CampusArticlePage> getArticles({
    int page = 1,
    int pageSize = 20,
    String? categorySlug,
  }) async {
    return CampusArticlePage(
      items: const <CampusArticleSummary>[],
      page: page,
      pageSize: pageSize,
      hasMore: false,
    );
  }
}

CourseScheduleSettingsSnapshot _snapshot() {
  return const CourseScheduleSettingsSnapshot(
    courseCount: 0,
    semesterStartText: '未设置，用于计算当前教学周',
    reminderEnabled: false,
    reminderAdvanceMinutes: 5,
    reminderBusy: false,
    scheduledReminderCount: 0,
    reminderSummary: '已关闭课程提醒',
    backgroundKeepAliveSubtitle: '建议授权：电池优化白名单、精确闹钟',
    backgroundKeepAliveReady: false,
    backgroundKeepAliveSupported: true,
    backgroundKeepAliveBusy: false,
    scheduleCardOpacity: 0.55,
    scheduleSlotHeight: 72,
    defaultSlotHeight: 72,
  );
}

CourseScheduleSettingsCallbacks _callbacks() {
  return CourseScheduleSettingsCallbacks(
    reloadSnapshot: () async => _snapshot(),
    refreshCourses: () async {},
    openArchive: () async {},
    pickSemesterStart: () async {},
    shareSchedule: () async {},
    addCustomCourse: () async {},
    toggleReminder: (_) async {},
    changeReminderAdvanceMinutes: (_) async {},
    requestBackgroundKeepAlive: () async {},
    openHomeWidgets: () async {},
    updateScheduleOpacity: (_) async {},
    updateScheduleSlotHeight: (_) async {},
    resetScheduleDisplay: () async {},
  );
}

void _setCanonicalViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('校园资讯与课表设置共享品牌 accent 与页面 surface', (tester) async {
    _setCanonicalViewport(tester);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: CampusArticleListScreen(service: _EmptyArticleService()),
      ),
    );
    await tester.pumpAndSettle();

    final articleTitle = find.text('校园资讯');
    expect(
      Theme.of(tester.element(articleTitle)).colorScheme.primary,
      CampusTheme.primary,
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      CampusTheme.bg,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: CourseScheduleSettingsScreen(
          initialSnapshot: _snapshot(),
          callbacks: _callbacks(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final settingsTitle = find.text('课表管理与显示');
    expect(
      Theme.of(tester.element(settingsTitle)).colorScheme.primary,
      CampusTheme.primary,
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      CampusTheme.bg,
    );
    expect(find.text('已关闭课程提醒'), findsOneWidget);
  });

  testWidgets('统一配色在暗色与大字号下保持可渲染', (tester) async {
    _setCanonicalViewport(tester);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: CourseScheduleSettingsScreen(
            initialSnapshot: _snapshot(),
            callbacks: _callbacks(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('课表设置'), findsOneWidget);
    expect(find.text('课表管理与显示'), findsOneWidget);
  });
}
