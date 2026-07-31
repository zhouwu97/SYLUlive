import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/competition/competition_my_hub_screen.dart';

class _HubAdapter implements HttpClientAdapter {
  final List<String> paths = [];

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
