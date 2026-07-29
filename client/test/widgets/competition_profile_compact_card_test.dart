import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition_dashboard_summary.dart';
import 'package:shenliyuan/widgets/competition/competition_profile_compact_card.dart';

const _summary = CompetitionDashboardSummary(
  preferenceConfigured: true,
  primaryGoal: 'ability',
  primaryDirection: '算法',
  weeklyHours: 7,
  awardTotal: 3,
  verifiedAwardCount: 1,
  selfReportedAwardCount: 1,
  pendingAwardCount: 1,
  rejectedAwardCount: 0,
  capabilityReady: true,
);

Widget _app({
  bool loggedIn = true,
  CompetitionDashboardSummary? summary = _summary,
  String? error,
  VoidCallback? onRetry,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CompetitionProfileCompactCard(
        isLoggedIn: loggedIn,
        summary: summary,
        loading: false,
        error: error,
        onTap: () {},
        onRetry: onRetry ?? () {},
      ),
    ),
  );
}

void main() {
  testWidgets('首页档案组件固定为紧凑高度并显示核验中摘要', (tester) async {
    await tester.pumpWidget(_app());

    expect(find.text('我的竞赛档案'), findsOneWidget);
    expect(find.text('3段经历 · 1项核验中 · 查看竞赛画像'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const Key('competition-profile-compact-card')))
          .height,
      68,
    );
  });

  testWidgets('加载失败保留档案结构并提供右侧重试', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        summary: null,
        error: '网络错误',
        onRetry: () => retried = true,
      ),
    );

    expect(find.text('我的竞赛档案'), findsOneWidget);
    expect(find.text('竞赛档案暂时无法读取'), findsOneWidget);
    await tester.tap(find.byKey(const Key('competition-profile-retry')));
    expect(retried, isTrue);
  });

  testWidgets('未登录时展示登录后管理提示', (tester) async {
    await tester.pumpWidget(_app(loggedIn: false, summary: null));
    expect(find.text('登录后管理竞赛目标、经历与能力画像'), findsOneWidget);
  });

  testWidgets('只设置目标时显示画像待完善状态', (tester) async {
    await tester.pumpWidget(
      _app(
        summary: const CompetitionDashboardSummary(
          preferenceConfigured: true,
          primaryGoal: 'ability',
          primaryDirection: '算法',
          weeklyHours: 7,
          awardTotal: 0,
          verifiedAwardCount: 0,
          selfReportedAwardCount: 0,
          pendingAwardCount: 0,
          rejectedAwardCount: 0,
          capabilityReady: true,
        ),
      ),
    );
    expect(find.text('目标已设置 · 暂无竞赛经历 · 画像待完善'), findsOneWidget);
  });
}
