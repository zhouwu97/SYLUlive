import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition.dart';
import 'package:shenliyuan/widgets/competition/competition_match_reason_sheet.dart';

CompetitionEvent _event() {
  return CompetitionEvent(
    id: 21,
    competitionId: 'COMP-2026-021',
    title: '全国大学生数据分析竞赛',
    matchDimensions: const CompetitionMatchDimensions(
      eligibility: 'matched',
      major: 'matched',
      college: 'partial',
      grade: 'unknown',
      goal: 'matched',
      skill: 'partial',
      time: 'unmatched',
    ),
    cautions: const ['校内名额仍需确认', '报名截止日期待核验'],
    questionsToConfirm: const ['是否可以接受跨学院组队'],
    evidenceSubgrade: 'B1',
    datasetVersion: 'catalog-2026-07',
    recordHash: 'secret-record-hash',
    updatedAt: DateTime.utc(2026, 7, 29),
    gates: const CompetitionRecommendationGates(
      candidatePoolAllowed: true,
      permissionLevel: 'blocked-internal-value',
      aiMode: 'candidate_explanation',
    ),
  );
}

Widget _app({
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: CompetitionMatchReasonSheet(event: _event())),
    ),
  );
}

void main() {
  testWidgets('展示匹配维度、风险、待确认项和目录依据', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('为什么进入候选'), findsOneWidget);
    expect(find.text('参赛资格'), findsOneWidget);
    expect(find.text('符合'), findsAtLeastNWidgets(1));
    expect(find.text('部分匹配'), findsAtLeastNWidgets(1));
    expect(find.text('不符合'), findsOneWidget);
    expect(find.text('尚未确认'), findsAtLeastNWidgets(1));
    expect(find.text('校内名额仍需确认'), findsOneWidget);
    expect(find.text('是否可以接受跨学院组队'), findsOneWidget);
    expect(find.text('catalog-2026-07'), findsOneWidget);
    expect(find.text('COMP-2026-021'), findsOneWidget);
    expect(find.text('2026-07-29'), findsOneWidget);
    expect(find.textContaining('获奖概率'), findsOneWidget);

    // 内部哈希与权限门只参与服务端审计，不进入学生可见解释。
    expect(find.textContaining('secret-record-hash'), findsNothing);
    expect(find.textContaining('blocked-internal-value'), findsNothing);
  });

  testWidgets('小屏深色大字体布局不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(brightness: Brightness.dark, textScale: 1.8),
    );
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(160, 400), const Offset(0, -900));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
