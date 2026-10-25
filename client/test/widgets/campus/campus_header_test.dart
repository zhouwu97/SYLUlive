import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/campus_calendar.dart';
import 'package:shenliyuan/providers/campus_calendar_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/widgets/campus/campus_header.dart';

import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';
import '../../helpers/load_test_fonts.dart';

class _CalendarProvider extends ChangeNotifier
    implements CampusCalendarProvider {
  @override
  CampusCalendar? calendar;

  void publish(CampusCalendar value) {
    calendar = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late CampusCalendar calendar;
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  setUpAll(() async {
    await loadTestFonts();
    final raw = await rootBundle
        .loadString('assets/data/campus_calendar_fallback.json');
    calendar = CampusCalendar.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  });

  Future<_CalendarProvider> pumpHeader(
    WidgetTester tester,
    DateTime date, {
    bool loaded = true,
    ThemeMode mode = ThemeMode.light,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final provider = _CalendarProvider()..calendar = loaded ? calendar : null;
    await tester.pumpWidget(ChangeNotifierProvider<CampusCalendarProvider>(
      create: (_) => provider,
      child: GoldenTestApp(
        themeMode: mode,
        textScaler: textScaler,
        home: Scaffold(
          body: CampusHeader(semester: '待确认学期', date: date),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return provider;
  }

  testWidgets('October 23 uses calendar week 9 and real semester progress',
      (tester) async {
    await pumpHeader(tester, DateTime(2026, 10, 23, 19));
    expect(find.text('第9周'), findsOneWidget);
    expect(find.text('第18周'), findsNothing);
    expect(find.text('2026—2027学年 · 第一学期'), findsOneWidget);
    expect(find.text('10-23'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        9 / 20);
  });

  for (final (date, label) in [
    (DateTime(2026, 8, 24), '第1周'),
    (DateTime(2027, 1, 10, 23, 59), '第20周'),
    (DateTime(2027, 2, 22), '第1周'),
  ]) {
    testWidgets('teaching week boundary $date is $label', (tester) async {
      await pumpHeader(tester, date);
      expect(find.text(label), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final date in [DateTime(2027, 1, 11), DateTime(2030, 10, 23)]) {
    testWidgets('holiday or uncovered date $date does not invent a week',
        (tester) async {
      await pumpHeader(tester, date);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining(RegExp(r'^第\d+周$')), findsNothing);
    });
  }

  testWidgets('calendar loading and failure do not display a placeholder week',
      (tester) async {
    final provider =
        await pumpHeader(tester, DateTime(2026, 10, 23), loaded: false);
    expect(find.text('10-23'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('第18周'), findsNothing);
    provider.publish(calendar);
    await tester.pumpAndSettle();
    expect(find.text('第9周'), findsOneWidget);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('周次徽标沿用父卡片玻璃，开关关闭恢复底色 $mode', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setFrostedGlass(true);
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: theme),
            ChangeNotifierProvider<CampusCalendarProvider>(
                create: (_) => _CalendarProvider()..calendar = calendar),
          ],
          child: GoldenTestApp(
              themeMode: mode,
              home: Scaffold(
                  body: CampusHeader(
                      semester: '第一学期', date: DateTime(2026, 10, 25))))));
      await tester.pumpAndSettle();
      BoxDecoration badge() => tester
          .widget<Container>(find.byKey(const ValueKey('campus-week-badge')))
          .decoration! as BoxDecoration;
      expect(badge().color, Colors.transparent);
      expect(badge().border, isNull);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text('第9周'), findsOneWidget);
      expect(find.text('10-25'), findsOneWidget);
      await theme.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(badge().color!.a, greaterThan(0));
      expect(badge().border, isNotNull);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('header supports large text in $mode', (tester) async {
      await pumpHeader(tester, DateTime(2026, 10, 23),
          mode: mode, textScaler: const TextScaler.linear(1.3));
      expect(find.text('第9周'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
