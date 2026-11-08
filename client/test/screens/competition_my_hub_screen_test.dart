import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/competition/competition_my_hub_screen.dart';

class _HubAdapter implements HttpClientAdapter {
  final List<String> paths = [];
  int candidateStatus = 200;
  bool holdCandidates = false;
  final pendingCandidates = <Completer<ResponseBody>>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    if (options.path.endsWith('/ai-access')) {
      return _json({'enabled': false, 'enabled_at': null});
    }
    if (options.path.endsWith('/dashboard')) {
      return _json({
        'preference_configured': true,
        'primary_goal': 'ability',
        'primary_direction': '算法',
        'weekly_hours': 7,
        'award_total': 3,
        'verified_award_count': 1,
        'self_reported_award_count': 1,
        'pending_award_count': 1,
        'rejected_award_count': 0,
        'capability_ready': true,
      });
    }
    if (options.path.endsWith('/user/competitions/candidates')) {
      if (holdCandidates) {
        final result = Completer<ResponseBody>();
        pendingCandidates.add(result);
        return result.future;
      }
      if (candidateStatus != 200) {
        return ResponseBody.fromString('{"error":"not found"}', candidateStatus,
            headers: {
              Headers.contentTypeHeader: ['application/json']
            });
      }

      return _json({
        'total': 6,
        'groups': const [],
        'catalog': const {'dataset_version': 'catalog-2026-07'},
      });
    }
    return _json({
      'preference_configured': true,
      'verified_award_count': 1,
      'self_reported_award_count': 1,
      'skill_summary': [
        {'skill': '算法', 'verified_count': 1, 'self_reported_count': 0},
      ],
      'role_summary': [
        {'role': 'developer', 'verified_count': 1, 'self_reported_count': 0},
      ],
      'direction_tags': ['算法'],
      'preferred_roles': ['developer'],
      'weekly_hours': 7,
      'accept_long_term_training': true,
    });
  }
}

ResponseBody _json(Object data) => ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  for (final status in [404, 500, 503, 401, 403]) {
    testWidgets('候选接口 $status 不伪装为资料删除或空候选，重试可恢复', (tester) async {
      final adapter = _HubAdapter()..candidateStatus = status;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;
      await tester.pumpWidget(
          MaterialApp(home: CompetitionMyHubScreen(dio: dio, accountKey: 1)));
      await tester.pumpAndSettle();
      expect(find.text('0项'), findsNothing);
      expect(find.text('请求的内容不存在或已被删除'), findsNothing);
      expect(
          find.text(status == 404
              ? '未开放'
              : status >= 500
                  ? '暂不可用'
                  : '重试'),
          findsOneWidget);
      if (status == 404) {
        expect(find.text('当前服务尚未开放候选匹配，请稍后重试'), findsOneWidget);
      }
      adapter.candidateStatus = 200;
      await tester.tap(find.text('匹配候选'));
      await tester.pumpAndSettle();
      expect(find.text('6项'), findsOneWidget);
      expect(find.text('未开放'), findsNothing);
      expect(find.text('暂不可用'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('切换账号 A → B → A 后旧候选请求不覆盖新结果', (tester) async {
    final adapter = _HubAdapter()..holdCandidates = true;
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
      ..httpClientAdapter = adapter;
    Future<void> show(int account) async {
      await tester.pumpWidget(MaterialApp(
          home: CompetitionMyHubScreen(dio: dio, accountKey: account)));
      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await show(1);
    await show(2);
    await show(1);
    expect(adapter.pendingCandidates, hasLength(3));
    adapter.pendingCandidates[2].complete(_json({'total': 6}));
    await tester.pumpAndSettle();
    expect(find.text('6项'), findsOneWidget);
    adapter.pendingCandidates[0].complete(_json({'total': 99}));
    adapter.pendingCandidates[1].complete(_json({'total': 77}));
    await tester.pumpAndSettle();
    expect(find.text('6项'), findsOneWidget);
    expect(find.text('99项'), findsNothing);
    expect(find.text('77项'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('汇总页用一个四行卡片展示目标、经历、画像和候选', (tester) async {
    final adapter = _HubAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
      ..httpClientAdapter = adapter;

    await tester.pumpWidget(
      MaterialApp(
        home: CompetitionMyHubScreen(dio: dio, accountKey: 1),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('竞赛目标'), findsOneWidget);
    expect(find.text('竞赛经历'), findsOneWidget);
    expect(find.text('能力画像'), findsOneWidget);
    expect(find.text('匹配候选'), findsOneWidget);
    expect(find.text('3段'), findsOneWidget);
    expect(find.text('6项'), findsOneWidget);
    expect(find.text('1项技能 · 主要角色：开发'), findsOneWidget);
    expect(find.text('允许 AI 解释竞赛匹配'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(adapter.paths, isNot(contains('/user/competition-awards')));
  });
}
