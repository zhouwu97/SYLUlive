import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_asset_ref.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';
import '../../helpers/golden_viewport.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('Recent 选择、清空与账号切换，大字号 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final prefs = MemoryPreferencesStore();
      final recent = EmojiRecentManager(preferencesLoader: () async => prefs)
        ..switchUser('1');
      await recent.load();
      await recent.recordSent(const EmojiAssetRef(assetKey: 'unicode:😀'),
          accountId: '1');
      String? selected;
      await tester.pumpWidget(MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
              child: Scaffold(
                  body: SizedBox(
                      height: 280,
                      child: AppEmojiPanel(
                        recentManager: recent,
                        favoriteService: EmojiFavoriteService(
                            preferencesLoader: () async => prefs),
                        onEmojiSelected: (value) => selected = value,
                        onBackspace: () {},
                      ))))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-tab-recent')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('emoji-recent-grid')),
          matching: find.text('😀')));
      expect(selected, '😀');
      expect((await recent.load()).single.useCount, 1);
      recent.switchUser('2');
      await tester.pumpAndSettle();
      expect(find.text('发送表情后会显示在这里'), findsOneWidget);
      recent.switchUser('1');
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空最近'));
      await tester.pumpAndSettle();
      expect(find.text('发送表情后会显示在这里'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
