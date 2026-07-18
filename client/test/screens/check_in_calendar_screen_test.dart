import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/check_in_calendar_screen.dart';

class _CheckInAdapter implements HttpClientAdapter {
  _CheckInAdapter({this.checkedIn = true});

  String? makeupDate;
  bool checkedIn;
  int checkInRequestCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST' && options.path == '/user/checkin') {
      checkInRequestCount++;
      checkedIn = true;
      return _jsonResponse({
        'already': false,
        'check_in_date': '2026-07-17',
        'streak_days': 18,
        'exp_earned': 18,
      });
    }
    if (options.method == 'POST' && options.path == '/user/checkin/makeup') {
      makeupDate = (options.data as Map)['check_in_date'] as String;
      return _jsonResponse({
        'success': true,
        'already': false,
        'check_in_date': makeupDate,
        'streak_days': 17,
        'check_in_exp': 16,
        'exp_earned': 16,
        'total_exp': 100,
        'makeup_cards': 0,
        'makeup_cards_awarded': 0,
      });
    }
    final requestedMonth =
        options.queryParameters['month']?.toString() ?? '2026-07';
    final body = switch (options.path) {
      '/user/checkin/status' => {
          'checked_in': checkedIn,
          'check_in_date': '2026-07-17',
          'streak_days': 17,
          'next_exp': 18,
          'makeup_cards': makeupDate == null ? 1 : 0,
        },
      '/user/checkin/calendar' => {
          'month': requestedMonth,
          'longest_streak': 17,
          'records': [
            if (requestedMonth == '2026-06')
              {
                'check_in_date': '2026-06-30',
                'streak_days': 16,
                'exp_earned': 16,
                'is_makeup': false,
              }
            else if (makeupDate != null)
              {
                'check_in_date': makeupDate,
                'streak_days': 16,
                'exp_earned': 16,
                'is_makeup': true,
              },
            if (requestedMonth == '2026-07' && checkedIn)
              {
                'check_in_date': '2026-07-17',
                'streak_days': 17,
                'exp_earned': 17,
                'is_makeup': false,
              },
          ],
        },
      _ => {'error': 'not mocked: ${options.path}'},
    };
    final statusCode = options.path.startsWith('/user/checkin/') ? 200 : 500;
    return _jsonResponse(body, statusCode: statusCode);
  }

  ResponseBody _jsonResponse(
    Object body, {
    int statusCode = 200,
  }) {
    return ResponseBody.fromString(jsonEncode(body), statusCode, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

void main() {
  testWidgets('签到月历固定展示六周并标记签到日期', (tester) async {
    final semantics = tester.ensureSemantics();
    final records = {
      DateTime(2026, 7, 1): CheckInDayRecord(
        date: DateTime(2026, 7, 1),
        streakDays: 1,
        expEarned: 1,
      ),
      DateTime(2026, 7, 15): CheckInDayRecord(
        date: DateTime(2026, 7, 15),
        streakDays: 2,
        expEarned: 1,
      ),
      DateTime(2026, 7, 17): CheckInDayRecord(
        date: DateTime(2026, 7, 17),
        streakDays: 3,
        expEarned: 1,
      ),
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: CheckInMonthCalendar(
              month: DateTime(2026, 7),
              today: DateTime(2026, 7, 17),
              records: records,
            ),
          ),
        ),
      ),
    );

    expect(find.text('31'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsWidgets);
    expect(find.byIcon(Icons.close_rounded), findsWidgets);
    expect(find.bySemanticsLabel('7月4日，未签到'), findsOneWidget);
    expect(find.bySemanticsLabel('7月17日，今天，已签到'), findsOneWidget);
    expect(
      tester.getCenter(find.text('日')).dx,
      lessThan(tester.getCenter(find.text('一')).dx),
    );
    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('设备日期落后时使用服务器日期标记今天', (tester) async {
    final semantics = tester.ensureSemantics();
    final dio = Dio()..httpClientAdapter = _CheckInAdapter();
    final auth = AuthProvider(dio, loadStoredAuth: false);

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: CheckInCalendarScreen(
            now: () => DateTime(2026, 7, 16),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('7月17日，今天，已签到'), findsOneWidget);
    expect(find.bySemanticsLabel('7月16日，未签到'), findsOneWidget);
    expect(tester.takeException(), isNull);
    auth.dispose();
    semantics.dispose();
  });

  testWidgets('从未签到入口进入后自动签到且只提交一次', (tester) async {
    final adapter = _CheckInAdapter(checkedIn: false);
    final dio = Dio()..httpClientAdapter = adapter;
    final auth = AuthProvider(dio, loadStoredAuth: false);

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: CheckInCalendarScreen(
            autoCheckIn: true,
            now: () => DateTime(2026, 7, 17),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(adapter.checkInRequestCount, 1);
    expect(find.text('签到成功'), findsOneWidget);
    expect(find.bySemanticsLabel('7月17日，今天，已签到'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    auth.dispose();
  });

  testWidgets('已签到时进入日历不会重复提交签到', (tester) async {
    final adapter = _CheckInAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final auth = AuthProvider(dio, loadStoredAuth: false);

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: CheckInCalendarScreen(
            autoCheckIn: true,
            now: () => DateTime(2026, 7, 17),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(adapter.checkInRequestCount, 0);
    expect(find.text('今日已签到'), findsOneWidget);
    expect(tester.takeException(), isNull);
    auth.dispose();
  });

  testWidgets('签到日历支持左右滑动切换月份', (tester) async {
    final dio = Dio()..httpClientAdapter = _CheckInAdapter();
    final auth = AuthProvider(dio, loadStoredAuth: false);

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: CheckInCalendarScreen(
            now: () => DateTime(2026, 7, 17),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.text('2026年7月'),
      const Offset(320, 0),
      900,
    );
    await tester.pumpAndSettle();
    expect(find.text('2026年6月'), findsOneWidget);

    await tester.fling(
      find.text('2026年6月'),
      const Offset(-320, 0),
      900,
    );
    await tester.pumpAndSettle();
    expect(find.text('2026年7月'), findsOneWidget);
    expect(tester.takeException(), isNull);
    auth.dispose();
  });

  testWidgets('点击已签到日期后圈选并在底栏显示状态', (tester) async {
    final semantics = tester.ensureSemantics();
    final dio = Dio()..httpClientAdapter = _CheckInAdapter();
    final auth = AuthProvider(dio, loadStoredAuth: false);

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: CheckInCalendarScreen(
            now: () => DateTime(2026, 7, 17),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final signedDay = find.bySemanticsLabel('7月17日，今天，已签到');
    await tester.ensureVisible(signedDay);
    await tester.pumpAndSettle();
    await tester.tap(signedDay);
    await tester.pump();
    expect(find.text('7 月 17 日已签到'), findsOneWidget);
    expect(
      find.bySemanticsLabel('7月17日，今天，已签到，已选择'),
      findsOneWidget,
    );
    final signedDayContainer = tester.widget<Container>(
      find.byKey(const ValueKey('check-in-day-2026-07-17')),
    );
    final signedDayDecoration = signedDayContainer.decoration! as BoxDecoration;
    expect(
      signedDayDecoration.border,
      Border.all(color: const Color(0xFF8F665F), width: 1.5),
    );
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    auth.dispose();
    semantics.dispose();
  });

  testWidgets('历史月份日期按签到状态显示反馈', (tester) async {
    final semantics = tester.ensureSemantics();
    final dio = Dio()..httpClientAdapter = _CheckInAdapter();
    final auth = AuthProvider(dio, loadStoredAuth: false);

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: CheckInCalendarScreen(
            now: () => DateTime(2026, 7, 17),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pumpAndSettle();

    final historicalSignedDay = find.bySemanticsLabel('6月30日，已签到');
    await tester.ensureVisible(historicalSignedDay);
    await tester.pumpAndSettle();
    await tester.tap(historicalSignedDay);
    await tester.pump();
    expect(find.text('6 月 30 日已签到'), findsOneWidget);
    expect(
      find.bySemanticsLabel('6月30日，已签到，已选择'),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);

    final historicalMissedDay = find.bySemanticsLabel('6月29日，未签到');
    await tester.ensureVisible(historicalMissedDay);
    await tester.pumpAndSettle();
    await tester.tap(historicalMissedDay);
    await tester.pump();
    expect(find.text('非本月日期不可补签'), findsOneWidget);
    expect(
      find.bySemanticsLabel('6月29日，未签到，已选择'),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    auth.dispose();
    semantics.dispose();
  });

  testWidgets('选择漏签日期后确认使用补签卡', (tester) async {
    final semantics = tester.ensureSemantics();
    final adapter = _CheckInAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final auth = AuthProvider(dio, loadStoredAuth: false);

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: CheckInCalendarScreen(
            now: () => DateTime(2026, 7, 16),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('补签卡 1 张'), findsOneWidget);
    final missedDay = find.bySemanticsLabel('7月16日，未签到');
    await tester.ensureVisible(missedDay);
    await tester.pumpAndSettle();
    await tester.tap(missedDay);
    await tester.pump();
    expect(find.text('使用补签卡补签 7 月 16 日'), findsOneWidget);
    final actionDecoration = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('check-in-primary-action-gradient')),
    );
    final actionGradient = (actionDecoration.decoration as BoxDecoration)
        .gradient! as LinearGradient;
    expect(
      actionGradient.colors,
      const [Color(0xFF666666), Color(0xFF292929)],
    );

    await tester.tap(find.text('使用补签卡补签 7 月 16 日'));
    await tester.pumpAndSettle();
    expect(find.text('使用补签卡'), findsOneWidget);
    final confirmButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('确认补签'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(
      confirmButton.style?.backgroundColor?.resolve(<WidgetState>{}),
      const Color(0xFF363636),
    );
    await tester.tap(find.text('确认补签'));
    await tester.pumpAndSettle();

    expect(adapter.makeupDate, '2026-07-16');
    expect(find.bySemanticsLabel('7月16日，已补签'), findsOneWidget);
    expect(find.bySemanticsLabel('补签卡 0 张'), findsOneWidget);
    expect(tester.takeException(), isNull);
    auth.dispose();
    semantics.dispose();
  });
}
