import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/browsing_history_item.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/repositories/browsing_history_repository.dart';
import 'package:shenliyuan/widgets/app_card.dart';

import '../helpers/content_surface_fixtures.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    testWidgets('浏览记录仅在两行之间分隔，删除后卡片底边不留线 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final appearance = ThemeProvider(loadOnStart: false);
      addTearDown(appearance.dispose);
      final repository = BrowsingHistoryRepository();
      for (final id in ['1', '2']) {
        await repository.recordVisit(
            userId: '1',
            targetId: id,
            type: BrowsingHistoryType.post,
            title: '浏览记录 $id');
      }
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: appearance,
        child: GoldenTestApp(
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: surfaceFixtureScene('history', surfaceFixtureDio()),
        ),
      ));
      await tester.pumpAndSettle();
      final card = find.byType(AppCardMaterial);
      final divider =
          find.descendant(of: card, matching: find.byType(AppCardDivider));
      expect(divider, findsOneWidget);
      final cardRect = tester.getRect(card);
      final lineRect = tester.getRect(divider);
      expect(lineRect.top, greaterThan(cardRect.top));
      expect(lineRect.bottom, lessThan(cardRect.bottom));
      final line = tester.widget<AppCardDivider>(divider);
      expect(line.indent, 16);
      expect(line.endIndent, 16);

      await tester.tap(find.byTooltip('删除此条记录').first);
      await tester.pumpAndSettle();
      expect(find.byType(Dismissible), findsOneWidget);
      expect(divider, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
