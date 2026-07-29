import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';

void main() {
  testWidgets('empty collection opens the favorite page', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiFavoriteService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 280,
          child: AppEmojiPanel(
            favoriteService: service,
            onEmojiSelected: (_) {},
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无收藏的表情'), findsOneWidget);
    expect(find.byKey(const ValueKey('emoji-tab-favorite')), findsOneWidget);
    expect(find.byIcon(Icons.history_rounded), findsNothing);
  });

  testWidgets('selects Emoji and exposes complete-character delete action',
      (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiFavoriteService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );
    String? selected;
    var deleted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 280,
          child: AppEmojiPanel(
            favoriteService: service,
            onEmojiSelected: (emoji) => selected = emoji,
            onBackspace: () => deleted = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('emoji-tab-face')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('😀').first);
    expect(selected, '😀');

    await tester.tap(find.byKey(const ValueKey('emoji-backspace-button')));
    expect(deleted, isTrue);
  });

  testWidgets('lays out saved favorites without overflow in narrow dark mode',
      (tester) async {
    final sticker = appStickerGroups.first.items.first;
    AppPreferencesStore.setMockInitialValues({
      EmojiFavoriteService.storageKey: jsonEncode([
        {'type': 'sticker', 'sticker_id': sticker.id},
      ]),
    });
    final service = EmojiFavoriteService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );
    tester.view.physicalSize = const Size(320, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SizedBox(
          height: 240,
          child: AppEmojiPanel(
            favoriteService: service,
            onEmojiSelected: (_) {},
            onStickerSelected: (_) {},
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(ValueKey('favorite-sticker:${sticker.id}')),
      findsOneWidget,
    );
  });

  testWidgets('selecting a saved image reports it to the composer',
      (tester) async {
    const imageUrl = '/uploads/favorite.png';
    AppPreferencesStore.setMockInitialValues({
      EmojiFavoriteService.storageKey: jsonEncode([
        {'type': 'image', 'image_url': imageUrl},
      ]),
    });
    final service = EmojiFavoriteService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );
    EmojiFavoriteItem? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 280,
          child: AppEmojiPanel(
            favoriteService: service,
            onEmojiSelected: (_) {},
            onFavoriteImageSelected: (favorite) => selected = favorite,
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('favorite-image:/uploads/favorite.png')),
    );
    expect(selected?.imageUrl, imageUrl);
  });

  testWidgets('long press adds a sticker to collection', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiFavoriteService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );
    final group = appStickerGroups.first;
    final sticker = group.items.first;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 320,
          child: AppEmojiPanel(
            favoriteService: service,
            onEmojiSelected: (_) {},
            onStickerSelected: (_) {},
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('sticker-pack-tab-${group.id}')),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(ValueKey('sticker-${sticker.id}')));
    await tester.pumpAndSettle();

    expect(await service.containsSticker(sticker.id), isTrue);
    await tester.tap(find.byKey(const ValueKey('emoji-tab-favorite')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('favorite-sticker:${sticker.id}')),
      findsOneWidget,
    );
  });

  testWidgets('horizontal swipes switch Emoji and sticker pack pages',
      (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiFavoriteService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 320,
          child: AppEmojiPanel(
            favoriteService: service,
            onEmojiSelected: (_) {},
            onStickerSelected: (_) {},
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pageView = find.byKey(const ValueKey('emoji-page-view'));
    await tester.flingFrom(
      tester.getCenter(pageView),
      const Offset(-500, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.text('😀'), findsOneWidget);

    await tester.flingFrom(
      tester.getCenter(pageView),
      const Offset(-500, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        ValueKey('sticker-pack-title-${appStickerGroups.first.id}'),
      ),
      findsOneWidget,
    );
  });
}
