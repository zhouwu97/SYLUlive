import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition_award.dart';
import 'package:shenliyuan/screens/competition/competition_award_editor_screen.dart';

class _EditorAdapter implements HttpClientAdapter {
  _EditorAdapter(this.handler);

  final FutureOr<ResponseBody> Function(
    RequestOptions options,
    String body,
  ) handler;
  int postCount = 0;
  int putCount = 0;
  final List<Map<String, dynamic>> postBodies = [];
  final List<Map<String, dynamic>> putBodies = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    await for (final chunk in requestStream ?? const Stream.empty()) {
      bytes.addAll(chunk);
    }
    final body = utf8.decode(bytes);
    if (options.method == 'POST' &&
        options.path.endsWith('competition-awards')) {
      postCount++;
      postBodies.add(Map<String, dynamic>.from(jsonDecode(body) as Map));
    }
    if (options.method == 'PUT') {
      putCount++;
      putBodies.add(Map<String, dynamic>.from(jsonDecode(body) as Map));
    }
    return handler(options, body);
  }
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

Dio _dio(_EditorAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
  dio.httpClientAdapter = adapter;
  return dio;
}

Widget _app(
  Dio dio, {
  double textScale = 1,
  CompetitionAward? initial,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: CompetitionAwardEditorScreen(dio: dio, initial: initial),
    ),
  );
}

Future<void> _fillRequired(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, '比赛名称'),
    '程序设计竞赛',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, '奖项名称'),
    '一等奖',
  );
}

void main() {
  testWidgets('默认手动赛事且可见范围为仅自己', (tester) async {
    final dio = _dio(_EditorAdapter((options, _) {
      if (options.method == 'GET') return _jsonResponse({'items': []});
      return _jsonResponse({});
    }));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, '比赛名称'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('暂不接入公开主页或组队推荐'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('仅自己'), findsOneWidget);
    expect(find.textContaining('暂不接入公开主页或组队推荐'), findsOneWidget);
  });

  testWidgets('支持从手动赛事切换到目录赛事', (tester) async {
    final dio = _dio(_EditorAdapter((options, _) {
      if (options.method == 'GET') {
        return _jsonResponse({
          'items': [
            {'id': 7, 'title': '全国大学生程序设计竞赛'},
          ],
        });
      }
      return _jsonResponse({});
    }));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    await tester.tap(find.text('目录赛事'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('competition-award-event')), findsOneWidget);
    expect(find.text('选择目录赛事'), findsOneWidget);
  });

  testWidgets('保存载荷默认私有且连续点击只请求一次', (tester) async {
    final saving = Completer<ResponseBody>();
    final adapter = _EditorAdapter((options, _) {
      if (options.method == 'GET') return _jsonResponse({'items': []});
      if (options.method == 'POST') return saving.future;
      return _jsonResponse({});
    });
    await tester.pumpWidget(_app(_dio(adapter)));
    await tester.pumpAndSettle();
    await _fillRequired(tester);

    await tester.tap(find.byKey(const Key('competition-award-save')));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byKey(const Key('competition-award-save')));
    await tester.pump(const Duration(milliseconds: 20));

    expect(adapter.postCount, 1);
    expect(adapter.postBodies.single['visibility'], 'private');
    expect(
        adapter.postBodies.single.containsKey('verification_status'), isFalse);

    saving.complete(_jsonResponse({'id': 1}));
    await tester.pumpAndSettle();
  });

  testWidgets('保存失败后保留表单内容', (tester) async {
    final dio = _dio(_EditorAdapter((options, _) {
      if (options.method == 'GET') return _jsonResponse({'items': []});
      return _jsonResponse({'error': '服务器拒绝保存'}, 500);
    }));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();
    await _fillRequired(tester);

    await tester.tap(find.byKey(const Key('competition-award-save')));
    await tester.pumpAndSettle();

    expect(find.text('程序设计竞赛'), findsOneWidget);
    expect(find.text('一等奖'), findsOneWidget);
    expect(find.text('服务器拒绝保存'), findsOneWidget);
  });

  testWidgets('已核验经历锁定核心字段且仅保存可见范围', (tester) async {
    final adapter = _EditorAdapter((options, _) {
      if (options.method == 'GET') return _jsonResponse({'items': []});
      return _jsonResponse({'id': 8});
    });
    const initial = CompetitionAward(
      id: 8,
      competitionTitle: '数学建模竞赛',
      competitionYear: 2025,
      awardName: '一等奖',
      competitionStage: 'national',
      role: 'modeler',
      verificationStatus: 'verified',
      visibility: 'private',
    );
    await tester.pumpWidget(_app(_dio(adapter), initial: initial));
    await tester.pumpAndSettle();

    expect(find.textContaining('当前状态：平台已核验'), findsOneWidget);
    expect(find.textContaining('核心信息和证明材料暂不可修改'), findsOneWidget);
    final awardField = tester.widget<TextFormField>(
      find.widgetWithText(TextFormField, '奖项名称'),
    );
    expect(awardField.enabled, isFalse);
    await tester.tap(find.byKey(const Key('competition-award-save')));
    await tester.pumpAndSettle();

    expect(adapter.putCount, 1);
    expect(adapter.putBodies.single['award_name'], '一等奖');
    expect(
        adapter.putBodies.single.containsKey('verification_status'), isFalse);
  });

  testWidgets('关联赛事不在当前目录页时仍回显标题快照', (tester) async {
    final adapter = _EditorAdapter((options, _) {
      if (options.method == 'GET') return _jsonResponse({'items': []});
      return _jsonResponse({'id': 9});
    });
    const initial = CompetitionAward(
      id: 9,
      competitionEventId: 99,
      competitionTitle: '已下架但需要保留的赛事',
      competitionYear: 2024,
      awardName: '参赛经历',
      competitionStage: 'school',
      role: 'member',
    );
    await tester.pumpWidget(_app(_dio(adapter), initial: initial));
    await tester.pumpAndSettle();

    expect(find.textContaining('已下架但需要保留的赛事'), findsOneWidget);
    expect(find.textContaining('目录中不可用'), findsOneWidget);
  });

  testWidgets('小屏大字体表单可滚动且不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dio = _dio(_EditorAdapter((options, _) {
      if (options.method == 'GET') return _jsonResponse({'items': []});
      return _jsonResponse({});
    }));

    await tester.pumpWidget(_app(dio, textScale: 1.6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ListView), findsOneWidget);
  });
}
