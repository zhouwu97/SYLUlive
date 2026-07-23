import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/competition/competition_award_verification_admin_screen.dart';
import 'package:shenliyuan/screens/competition/competition_admin_center_screen.dart';

class _VerificationAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

  _VerificationAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      handler(options);
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json']
      },
    );

Dio _dio(_VerificationAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
  dio.httpClientAdapter = adapter;
  return dio;
}

Map<String, dynamic> _summary() => {
      'id': 8,
      'user_id': 12,
      'user_nickname': '小明',
      'competition_title': '程序设计竞赛',
      'competition_year': 2026,
      'award_name': '二等奖',
      'award_level': '省级',
      'verification_status': 'pending',
      'evidence_count': 1,
    };

Map<String, dynamic> _award() => {
      ..._summary(),
      'competition_stage': 'provincial',
      'role': 'developer',
      'skill_tags': ['Flutter'],
      'contribution_summary': '负责客户端开发',
      'evidence_file_ids': [99],
      'visibility': 'private',
    };

void main() {
  test('只有超级管理员显示经历核验入口', () {
    expect(canVerifyCompetitionAwards('super_admin'), isTrue);
    expect(canVerifyCompetitionAwards('admin'), isFalse);
    expect(canVerifyCompetitionAwards('user'), isFalse);
    expect(canVerifyCompetitionAwards(null), isFalse);
  });

  testWidgets('核验列表分页且进入详情前不读取材料', (tester) async {
    final pages = <int>[];
    var evidenceRequests = 0;
    final adapter = _VerificationAdapter((options) {
      if (options.path.endsWith('/verifications')) {
        pages.add((options.queryParameters['page'] as num).toInt());
        return _json({
          'items': [_summary()],
          'total': 21,
          'page': options.queryParameters['page'],
          'page_size': 20,
        });
      }
      if (options.path.endsWith('/verifications/8')) {
        return _json({
          'award': _award(),
          'logs': [],
        });
      }
      if (options.path.endsWith('/evidence/99')) {
        evidenceRequests++;
        return ResponseBody.fromBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
          200,
          headers: {
            Headers.contentTypeHeader: ['image/png']
          },
        );
      }
      return _json({});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: CompetitionAwardVerificationAdminScreen(dio: _dio(adapter)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('小明 · 2026\n省级 · 二等奖 · 材料待核验 · 1 份材料'), findsOneWidget);
    expect(evidenceRequests, 0);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(pages, [1, 2]);

    await tester.tap(find.byKey(const Key('award-verification-8')));
    await tester.pumpAndSettle();
    expect(find.text('核验详情'), findsOneWidget);
    expect(evidenceRequests, 0);
    await tester.tap(find.byKey(const Key('award-evidence-99')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(evidenceRequests, 1);
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('待核验详情提供二次确认且驳回原因必填', (tester) async {
    var reviewRequests = 0;
    final adapter = _VerificationAdapter((options) {
      if (options.path.endsWith('/verifications/8')) {
        return _json({'award': _award(), 'logs': []});
      }
      if (options.method == 'POST') {
        reviewRequests++;
        return _json({'verification_status': 'rejected'});
      }
      return _json({});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: CompetitionAwardVerificationDetailScreen(
          dio: _dio(adapter),
          awardId: 8,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('award-verification-reject')));
    await tester.pumpAndSettle();
    expect(find.text('驳回材料核验？'), findsOneWidget);
    await tester.tap(find.text('确认驳回'));
    await tester.pump();
    expect(reviewRequests, 0);
    await tester.enterText(
      find.byKey(const Key('award-verification-note')),
      '材料无法确认奖项等级',
    );
    await tester.tap(find.text('确认驳回'));
    await tester.pumpAndSettle();
    expect(reviewRequests, 1);
  });
}
