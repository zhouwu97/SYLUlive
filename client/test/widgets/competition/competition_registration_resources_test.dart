import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition.dart';
import 'package:shenliyuan/platform/contracts/external_navigator.dart';
import 'package:shenliyuan/widgets/competition/competition_registration_resources.dart';

import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';
import '../../helpers/load_test_fonts.dart';

class _Navigator implements ExternalNavigator {
  Uri? opened;
  bool succeeds = true;

  @override
  Future<bool> open(Uri uri) async {
    opened = uri;
    return succeeds;
  }
}

void main() {
  setUpAll(loadTestFonts);

  Future<void> pump(WidgetTester tester, CompetitionEvent event,
      {ThemeMode mode = ThemeMode.light}) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(GoldenTestApp(
      themeMode: mode,
      textScaler: GoldenTextProfile.large.scaler,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: CompetitionRegistrationResources(event: event),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('无资料时说明待补充，不能将计划当成报名', (tester) async {
    await pump(tester, CompetitionEvent(id: 1, title: '比赛'));
    expect(find.textContaining('当届报名通知待补充'), findsOneWidget);
    expect(find.textContaining('不代表已完成报名'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('$mode 大字号下资料可打开、重复和无效链接不展示', (tester) async {
      final navigator = _Navigator();
      final previous = ExternalNavigator.current();
      ExternalNavigator.register(navigator);
      addTearDown(() => ExternalNavigator.register(previous));
      await pump(
        tester,
        CompetitionEvent(
          id: 1,
          title: '比赛',
          noticeUrl: 'https://university.example/notice',
          officialUrl: 'https://competition.example/',
          attachmentUrls: [
            'https://university.example/rules.pdf',
            'https://university.example/notice',
            'javascript:alert(1)',
            'not a url',
          ],
        ),
        mode: mode,
      );
      expect(find.byType(OutlinedButton), findsNWidgets(3));
      expect(find.textContaining('适用届次'), findsOneWidget);
      for (final button in find.byType(OutlinedButton).evaluate()) {
        expect(tester.getSize(find.byWidget(button.widget)).height,
            greaterThanOrEqualTo(44));
      }
      await tester.tap(find.text('查看附件 1'));
      await tester.pumpAndSettle();
      expect(
          navigator.opened.toString(), 'https://university.example/rules.pdf');
      navigator.succeeds = false;
      await tester.tap(find.text('查看通知'));
      await tester.pumpAndSettle();
      expect(find.text('链接暂时无法打开，请稍后重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
