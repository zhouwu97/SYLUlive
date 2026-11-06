import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';

import '../../helpers/emoji_flow_qa.dart';

void main() {
  setUpAll(loadEmojiQAFonts);
  for (final profile in [
    (name: 'light', theme: AppTheme.lightTheme, scale: 1.0),
    (name: 'dark large text', theme: AppTheme.darkTheme, scale: 1.3),
  ]) {
    testWidgets('内置表情图片、文字和发送 ID 一致 (${profile.name})', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        AppPreferencesStore.setMockInitialValues({});
        AppSticker? selected;
        final previewKey = GlobalKey();

        await tester.pumpWidget(MaterialApp(
          theme: profile.theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(profile.scale)),
            child: child!,
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: previewKey,
              child: SizedBox(
                height: 520,
                child: AppEmojiPanel(
                  favoriteService: EmojiFavoriteService(
                    preferencesLoader: AppPreferencesStore.getInstance,
                  ),
                  recentManager: EmojiRecentManager(
                    preferencesLoader: () async => MemoryPreferencesStore(),
                  ),
                  onEmojiSelected: (_) {},
                  onStickerSelected: (sticker) => selected = sticker,
                  onBackspace: () {},
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey('sticker-pack-tab-mingfeng-daily')));
        await tester.pumpAndSettle();

        const corrected = {
          '36286e5249dbbd659981ca530e21c047': '粘',
          '6608d1dacfcde27f87f7d3852330d0fb': '认真',
          '2d094a6c0e1ac32d31a65286eb141a57': '抱',
          '1c704494bbb89fce27681425cffbe6fa': '阿巴',
          'd0deb840abc781f414c7ad6824407964': '叹气',
          'f05144bf668463d3f2742765d6f8da14': '云里雾里',
        };
        for (final entry in corrected.entries) {
          final cell = find.byKey(ValueKey('sticker-${entry.key}'));
          expect(cell, findsOneWidget);
          await tester.ensureVisible(cell);
          await tester.pumpAndSettle();
          expect(find.descendant(of: cell, matching: find.text(entry.value)),
              findsOneWidget);
          final picture = tester.widget<Image>(
            find.descendant(of: cell, matching: find.byType(Image)).first,
          );
          expect((picture.image as AssetImage).assetName,
              'assets/images/stickers/mingfeng-daily/${entry.key}.png');
          expect(find.bySemanticsLabel(RegExp('发送表情 ${entry.value}')),
              findsOneWidget,
              reason: entry.key);
        }
        final firstCorrected = find
            .byKey(const ValueKey('sticker-36286e5249dbbd659981ca530e21c047'));
        await tester.ensureVisible(firstCorrected);
        await tester.pumpAndSettle();
        await tester.tap(firstCorrected);
        await tester.pumpAndSettle();
        expect(selected?.id, '36286e5249dbbd659981ca530e21c047');
        expect(selected?.label, '粘');
        final longLabel = find.text('敢这么说话');
        expect(longLabel, findsOneWidget);
        expect(tester.widget<Text>(longLabel).overflow, isNot(TextOverflow.ellipsis));
        expect(find.ancestor(of: longLabel, matching: find.byType(FittedBox)), findsWidgets);
        expect(tester.takeException(), isNull);
        await captureEmojiQA(
            tester,
            previewKey,
            profile.name == 'light'
                ? 'sticker-mapping'
                : 'sticker-mapping-dark');
      } finally {
        semantics.dispose();
      }
    });
  }
}
