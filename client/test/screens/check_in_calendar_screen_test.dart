import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/check_in_calendar_screen.dart';

class _CheckInAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = switch (options.path) {
      '/user/checkin/status' => {
          'checked_in': true,
          'check_in_date': '2026-07-17',
          'streak_days': 17,
          'next_exp': 18,
        },
      '/user/checkin/calendar' => {
          'month': '2026-07',
          'longest_streak': 17,
          'records': [
            {
              'check_in_date': '2026-07-17',
              'streak_days': 17,
              'exp_earned': 17,
            },
          ],
        },
      _ => {'error': 'not mocked: ${options.path}'},
    };
    final statusCode = options.path.startsWith('/user/checkin/') ? 200 : 500;
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
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
}
