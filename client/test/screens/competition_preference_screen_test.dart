import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/competition/competition_preference_screen.dart';

class _PreferenceAdapter implements HttpClientAdapter {
  _PreferenceAdapter(this.handler);

  final FutureOr<ResponseBody> Function(
    RequestOptions options,
    String body,
  ) handler;
  int getCount = 0;
  int putCount = 0;
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
    if (options.method == 'GET') getCount++;
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

Map<String, dynamic> _preference({
  bool configured = false,
  List<String> goals = const [],
  List<String> directions = const [],
  List<String> skills = const [],
  List<String> roles = const [],
  int weeklyHours = 0,
  bool longTerm = false,
  String career = '',
  String experience = 'beginner',
}) {
  return {
    'configured': configured,
    'goals': goals,
    'direction_tags': directions,
    'skill_tags': skills,
    'preferred_roles': roles,
    'weekly_hours': weeklyHours,
    'accept_long_term_training': longTerm,
    'career_direction': career,
    'experience_level': experience,
  };
}

Dio _dio(_PreferenceAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
  dio.httpClientAdapter = adapter;
  return dio;
}

Widget _app(Dio dio, {Object accountKey = 1, double textScale = 1}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: CompetitionPreferenceScreen(dio: dio, accountKey: accountKey),
    ),
  );
}

Future<void> _pumpLoaded(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未设置时显示默认可编辑页面', (tester) async {
    final adapter = _PreferenceAdapter((_, __) => _jsonResponse(_preference()));
    await _pumpLoaded(tester, _app(_dio(adapter)));

    expect(find.text('我的竞赛目标'), findsOneWidget);
    expect(find.text('简历提升'), findsOneWidget);
    expect(find.text('暂不确定'), findsOneWidget);
    expect(
        find.byKey(const Key('competition-preference-save')), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('competition-preference-save')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('修改后启用保存并在返回时确认未保存修改', (tester) async {
    final adapter = _PreferenceAdapter((_, __) => _jsonResponse(_preference()));
    await _pumpLoaded(tester, _app(_dio(adapter)));

    await tester.tap(find.text('能力成长'));
    await tester.pump();
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('competition-preference-save')),
    );
    expect(save.onPressed, isNotNull);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    expect(find.text('继续编辑'), findsOneWidget);
  });

  testWidgets('已设置偏好完整回显', (tester) async {
    final adapter = _PreferenceAdapter((_, __) => _jsonResponse(_preference(
          configured: true,
          goals: ['resume'],
          directions: ['程序设计'],
          skills: ['Python'],
          roles: ['developer'],
          weeklyHours: 7,
          longTerm: true,
          career: '后端开发',
          experience: 'participated',
        )));
    await _pumpLoaded(tester, _app(_dio(adapter)));

    expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '简历提升'))
            .selected,
        isTrue);
    expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '程序设计'))
            .selected,
        isTrue);
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '4～7 小时'))
            .selected,
        isTrue);
    expect(find.text('后端开发'), findsOneWidget);
  });

  testWidgets('多选达到上限后拒绝额外选择', (tester) async {
    final adapter = _PreferenceAdapter((options, body) {
      if (options.method == 'PUT') {
        final data = Map<String, dynamic>.from(jsonDecode(body) as Map);
        return _jsonResponse({...data, 'configured': true});
      }
      return _jsonResponse(_preference());
    });
    await _pumpLoaded(tester, _app(_dio(adapter)));

    for (final label in ['简历提升', '能力成长', '探索体验', '保研准备']) {
      await tester.tap(find.text(label));
      await tester.pump();
    }
    expect(find.text('最多选择 3 项'), findsOneWidget);
    expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '保研准备'))
            .selected,
        isFalse);
  });

  testWidgets('保存成功且连续点击只发起一次请求', (tester) async {
    final saveCompleter = Completer<ResponseBody>();
    final adapter = _PreferenceAdapter((options, body) {
      if (options.method == 'PUT') return saveCompleter.future;
      return _jsonResponse(_preference());
    });
    await _pumpLoaded(tester, _app(_dio(adapter)));
    await tester.tap(find.text('能力成长'));
    await tester.tap(find.byKey(const Key('competition-preference-save')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('competition-preference-save')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.putCount, 1);

    saveCompleter.complete(
        _jsonResponse(_preference(configured: true, goals: ['ability'])));
    await tester.pumpAndSettle();
    expect(find.text('竞赛目标已保存'), findsOneWidget);
  });

  testWidgets('保存失败保留当前输入', (tester) async {
    final adapter = _PreferenceAdapter((options, _) {
      if (options.method == 'PUT') {
        return _jsonResponse({'error': '暂时不可用'}, 500);
      }
      return _jsonResponse(_preference());
    });
    await _pumpLoaded(tester, _app(_dio(adapter)));
    await tester.tap(find.text('简历提升'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('competition-preference-save')));
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '简历提升'))
            .selected,
        isTrue);
    expect(adapter.putCount, 1);
    expect(find.textContaining('暂时不可用'), findsOneWidget);
  });

  testWidgets('账号变化时先清空旧偏好再加载新账号', (tester) async {
    final second = Completer<ResponseBody>();
    var getIndex = 0;
    final adapter = _PreferenceAdapter((options, _) {
      if (options.method == 'GET') {
        getIndex++;
        if (getIndex == 1) {
          return _jsonResponse(
              _preference(configured: true, goals: ['resume']));
        }
        return second.future;
      }
      return _jsonResponse(_preference());
    });
    final dio = _dio(adapter);
    await _pumpLoaded(tester, _app(dio, accountKey: 1));
    expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '简历提升'))
            .selected,
        isTrue);

    await tester.pumpWidget(_app(dio, accountKey: 2));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '简历提升'), findsNothing);

    second.complete(
        _jsonResponse(_preference(configured: true, goals: ['ability'])));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '能力成长'))
            .selected,
        isTrue);
  });

  testWidgets('毕业补齐显示学分免责声明', (tester) async {
    final adapter = _PreferenceAdapter((_, __) => _jsonResponse(_preference()));
    await _pumpLoaded(tester, _app(_dio(adapter)));
    expect(find.textContaining('不代表比赛一定可以获得毕业学分'), findsNothing);
    await tester.tap(find.text('毕业补齐'));
    await tester.pump();
    expect(find.textContaining('不代表比赛一定可以获得毕业学分'), findsOneWidget);
  });

  testWidgets('小屏大字体布局不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final adapter = _PreferenceAdapter((_, __) => _jsonResponse(_preference()));
    await _pumpLoaded(tester, _app(_dio(adapter), textScale: 2));
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -900));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
        find.byKey(const Key('competition-preference-save')), findsOneWidget);
  });
}
