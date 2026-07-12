import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/models/campus_calendar.dart';
import 'package:shenliyuan/providers/campus_calendar_provider.dart';
import 'package:shenliyuan/screens/campus_calendar_screen.dart';
import 'package:shenliyuan/services/campus_calendar_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('在月历上向左滑动会切换到下一个月', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final raw = await rootBundle.loadString(
      'assets/data/campus_calendar_fallback.json',
    );
    final calendar = CampusCalendar.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
    final provider = CampusCalendarProvider(_StaticCalendarService(calendar));
    await provider.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(home: CampusCalendarScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final initialMonth = DateTime(now.year, now.month);
    final nextMonth = DateTime(now.year, now.month + 1);
    final initialLabel = DateFormat('yyyy年M月').format(initialMonth);
    final nextLabel = DateFormat('yyyy年M月').format(nextMonth);

    expect(find.text(initialLabel), findsOneWidget);
    final pageView = find.byType(PageView);
    expect(pageView, findsOneWidget);
    final controller = tester.widget<PageView>(pageView).controller!;
    final initialPage = controller.page!;

    final gesture = await tester.startGesture(tester.getCenter(pageView));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-420, 0));
    await tester.pump();

    expect(controller.page, greaterThan(initialPage));

    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text(nextLabel), findsOneWidget);
  });

  testWidgets('相邻月份周数不同时半页拖动不会溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final raw = await rootBundle.loadString(
      'assets/data/campus_calendar_fallback.json',
    );
    final calendar = CampusCalendar.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
    final provider = CampusCalendarProvider(_StaticCalendarService(calendar));
    await provider.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(home: CampusCalendarScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final pageView = find.byType(PageView);
    final controller = tester.widget<PageView>(pageView).controller!;
    final septemberPage = controller.initialPage + 2;
    controller.jumpToPage(septemberPage);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(pageView));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(240, 0));
    await tester.pump();
    final dragException = tester.takeException();
    await gesture.up();
    await tester.pump();

    expect(controller.page, lessThan(septemberPage.toDouble()));
    expect(controller.page, greaterThan(septemberPage - 0.5));
    expect(dragException, isNull);
  });
}

class _StaticCalendarService extends CampusCalendarService {
  _StaticCalendarService(this.calendar) : super(Dio());

  final CampusCalendar calendar;

  @override
  Future<CampusCalendar?> loadCached() async => null;

  @override
  Future<CampusCalendar> loadFallback() async => calendar;

  @override
  Future<CampusCalendar?> fetchCurrent() async => null;

  @override
  Future<void> saveCached(CampusCalendar calendar) async {}
}
