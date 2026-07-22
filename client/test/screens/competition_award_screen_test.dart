import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/competition/competition_award_screen.dart';

class _AwardAdapter implements HttpClientAdapter {
  _AwardAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

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

ResponseBody _jsonResponse(Object data, [int status = 200]) {
  return ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

Dio _dio(_AwardAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
  dio.httpClientAdapter = adapter;
  return dio;
}

Widget _app(Dio dio, {Object accountKey = 1, double textScale = 1}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: CompetitionAwardScreen(dio: dio, accountKey: accountKey),
    ),
  );
}

Map<String, dynamic> _award({
  int id = 1,
  String title = '中国大学生计算机设计大赛',
  String status = 'self_reported',
}) {
  return {
    'id': id,
    'competition_title': title,
    'competition_year': 2026,
    'award_name': '二等奖',
    'award_level': '省级',
    'competition_stage': 'provincial',
    'role': 'developer',
    'verification_status': status,
    'visibility': 'private',
    'evidence_file_ids': [987654],
  };
}

void main() {
  testWidgets('空状态提供添加入口', (tester) async {
    final dio = _dio(_AwardAdapter((_) => _jsonResponse({'items': []})));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    expect(find.text('还没有竞赛经历'), findsOneWidget);
    expect(find.text('添加经历'), findsNWidgets(2));
  });

  testWidgets('列表区分核验状态且不暴露证明材料', (tester) async {
    final dio = _dio(_AwardAdapter((_) => _jsonResponse({
          'items': [
            _award(id: 1),
            _award(id: 2, title: '数学建模竞赛', status: 'verified'),
          ],
        })));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    expect(find.text('状态：本人填写'), findsOneWidget);
    expect(find.text('状态：平台已核验'), findsOneWidget);
    expect(find.text('可见范围：仅自己'), findsNWidgets(2));
    expect(find.textContaining('987654'), findsNothing);
    expect(find.textContaining('证明材料'), findsNothing);
  });

  testWidgets('账号变化时立即清空旧经历', (tester) async {
    final second = Completer<ResponseBody>();
    var count = 0;
    final dio = _dio(_AwardAdapter((_) {
      count++;
      if (count == 1) {
        return _jsonResponse({
          'items': [_award(title: '旧账号比赛')]
        });
      }
      return second.future;
    }));
    await tester.pumpWidget(_app(dio, accountKey: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('旧账号比赛'), findsOneWidget);

    await tester.pumpWidget(_app(dio, accountKey: 2));
    await tester.pump();
    expect(find.textContaining('旧账号比赛'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    second.complete(
      _jsonResponse({
        'items': [_award(title: '新账号比赛')]
      }),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('新账号比赛'), findsOneWidget);
  });

  testWidgets('小屏大字体列表不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dio = _dio(_AwardAdapter((_) => _jsonResponse({
          'items': [_award(title: '名称很长的全国大学生综合创新设计竞赛')],
        })));

    await tester.pumpWidget(_app(dio, textScale: 1.8));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
