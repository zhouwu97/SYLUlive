import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/canteen_ranking.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_radius.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/canteen/canteen_ranking_item.dart';
import 'package:shenliyuan/widgets/rating_detail/rating_policy_tip.dart';
import 'package:shenliyuan/widgets/rating_detail/rating_subject_header.dart';

import '../helpers/active_backdrop_filters.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('评价标题透明、说明仅一层底面 dark=$dark scale=$scale', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        await appearance.setComponentOpacity(.75);
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: appearance,
          child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: TextScaler.linear(scale),
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: Column(children: [
                  RatingSubjectHeader(
                    title: '程序设计老师',
                    subtitle: '程序设计基础',
                    initial: '程',
                    showInitialBadge: false,
                  ),
                  SizedBox(height: 12),
                  RatingPolicyTip(
                    text: '请只评价课堂体验，避免人身攻击和隐私信息。',
                    type: RatingPolicyType.warning,
                  ),
                ]),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final titleRect = tester.getRect(find.text('程序设计老师'));
        final policyRect = tester.getRect(find.byType(RatingPolicyTip));
        final surface = find.byType(AppCardSurface);
        expect(surface, findsOneWidget);
        expect(
            find.descendant(
                of: find.byType(RatingSubjectHeader), matching: surface),
            findsNothing);
        final box =
            tester.widget<AppCardSurface>(surface).decoration! as BoxDecoration;
        expect(box.borderRadius, BorderRadius.circular(AppRadius.md));
        expect(tester.getRect(surface).bottom, policyRect.bottom - 8);
        for (final glass in [true, false, true]) {
          await appearance.setFrostedGlass(glass);
          await tester.pumpAndSettle();
          expect(tester.getRect(find.text('程序设计老师')), titleRect);
          expect(tester.getRect(find.byType(RatingPolicyTip)), policyRect);
          expect(
              activeBackdropFilters(), glass ? findsOneWidget : findsNothing);
          expect(tester.takeException(), isNull);
        }
      });

      testWidgets('排行卡片保留排名与操作、元信息可换行 dark=$dark scale=$scale', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        var tapped = 0;
        var held = 0;
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: appearance,
          child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: TextScaler.linear(scale),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: CanteenRankingItemTile(
                  item: const CanteenRankingItem(
                    rank: 1,
                    id: 1,
                    name: '一食堂风味窗口',
                    averageStar: 4.8,
                    ratingCount: 128,
                    rankingScore: 86,
                    locationArea: '一食堂',
                    locationFloor: '二楼',
                    summaryTags: [
                      SummaryTag(key: 'taste', name: '味道不错', count: 8)
                    ],
                  ),
                  onTap: () => tapped++,
                  onLongPress: () => held++,
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final surface = find.byType(AppCardSurface);
        expect(surface, findsOneWidget);
        final shape = (tester.widget<AppCardSurface>(surface).decoration!
                as BoxDecoration)
            .borderRadius!
            .resolve(TextDirection.ltr)
            .toRRect(tester.getRect(surface));
        for (final label in ['01', '128 人评价', '一食堂·二楼', '综合分 86']) {
          final rect = tester.getRect(find.text(label));
          expect(shape.contains(rect.topLeft), isTrue, reason: label);
          expect(shape.contains(rect.bottomRight), isTrue, reason: label);
        }
        await tester.tap(find.text('01'));
        await tester.pumpAndSettle();
        await tester.longPress(find.text('01'));
        await tester.pumpAndSettle();
        expect(tapped, 1);
        expect(held, 1);
        final rect = tester.getRect(surface);
        await appearance.setFrostedGlass(true);
        await tester.pumpAndSettle();
        expect(tester.getRect(surface), rect);
        expect(activeBackdropFilters(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
