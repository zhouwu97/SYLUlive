import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition.dart';
import 'package:shenliyuan/widgets/competition/competition_status_helper.dart';
import 'package:shenliyuan/widgets/competition/competition_student_event_card.dart';

import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';
import '../../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  final now = DateTime(2026, 9, 8, 12);
  String status(CompetitionEvent event) =>
      resolveCompetitionStatus(event, false, now: now).label;

  test('报名尚未开始时不能显示报名中', () {
    expect(
        status(CompetitionEvent(
            id: 1,
            title: '测试',
            registrationStart: DateTime(2026, 9, 10),
            registrationEnd: DateTime(2026, 9, 20))),
        '报名未开始');
  });
  test('报名截止不等于比赛结束', () {
    expect(
        status(CompetitionEvent(
            id: 1,
            title: '测试',
            registrationEnd: DateTime(2026, 9, 7),
            eventStart: DateTime(2026, 9, 10))),
        '报名已截止');
  });
  test('比赛开始不推定比赛结束', () {
    expect(
        status(CompetitionEvent(
            id: 1, title: '测试', eventStart: DateTime(2026, 9, 7))),
        '比赛已开始');
    expect(
        status(CompetitionEvent(
            id: 1, title: '测试', eventStart: DateTime(2026, 9, 10))),
        '比赛未开始');
    expect(
        status(CompetitionEvent(
            id: 1, title: '测试', eventEnd: DateTime(2026, 9, 7))),
        '比赛已结束');
  });
  test('往年参考日期不触发当届即将截止状态', () {
    final event = CompetitionEvent(
        id: 1,
        title: '测试',
        timeStatus: 'historical',
        registrationEnd: DateTime(2026, 9, 9));
    expect(status(event), '往年参考');
    expect(competitionRegistrationText(event), startsWith('往年参考：'));
  });
  test('完全缺失与仅有比赛时间均明确指出报名待核实', () {
    expect(competitionRegistrationText(CompetitionEvent(id: 1, title: '测试')),
        '报名时间待核实');
    final event =
        CompetitionEvent(id: 1, title: '测试', eventStart: DateTime(2026, 9, 10));
    expect(getCompetitionCriticalTime(event), '报名时间待核实');
    expect(competitionEventTimeText(event), contains('2026-09-10'));
  });
  test('保留报名起止、精确到分钟和通知适用范围', () {
    final event = CompetitionEvent(
        id: 1,
        title: '测试',
        registrationStart: DateTime.parse('2026-06-01T08:00:00+08:00'),
        registrationEnd: DateTime.parse('2026-09-19T17:00:00+08:00'));
    expect(competitionRegistrationText(event),
        '2026-06-01 08:00 至 2026-09-19 17:00');
    expect(
        competitionRegistrationText(CompetitionEvent(
            id: 1,
            title: '测试',
            registrationTimeText: '全国截止9月19日17:00；沈理校内截止待核实')),
        '全国截止9月19日17:00；沈理校内截止待核实');
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('长报名安排在360px、1.3倍字号下完整显示 $mode', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      const text = '全国报名：2026-06-01 08:00 至 2026-09-19 17:00；沈阳理工大学校内截止另行核实';
      await tester.pumpWidget(GoldenTestApp(
        themeMode: mode,
        textScaler: GoldenTextProfile.large.scaler,
        home: Scaffold(
            body: SingleChildScrollView(
                child: CompetitionStudentEventCard(
          event: CompetitionEvent(
              id: 1, title: '中国研究生数学建模竞赛', registrationTimeText: text),
          onTap: () {},
          onAddPlan: () {},
          onJoinedTap: () {},
        ))),
      ));
      expect(find.text('报名安排：$text'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final label = tester.widget<Text>(find.text('报名安排：$text'));
      expect(label.maxLines, isNull);
    });
  }
}
