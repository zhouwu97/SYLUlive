import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../lib/services/emoji_recent_service.dart';
import '../../../lib/widgets/emoji/app_emoji_panel.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  testWidgets('empty recent history opens the first Emoji category',
      (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiRecentService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 280,
          child: AppEmojiPanel(
            recentService: service,
            onEmojiSelected: (_) {},
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('😀'), findsOneWidget);
    expect(find.text('暂无最近使用'), findsNothing);
  });

  testWidgets('selects Emoji and exposes complete-character delete action',
      (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiRecentService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );
    String? selected;
    var deleted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 280,
          child: AppEmojiPanel(
            recentService: service,
            onEmojiSelected: (emoji) => selected = emoji,
            onBackspace: () => deleted = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('表情'));
    await tester.pump();
    await tester.tap(find.text('😀').first);
    await tester.pumpAndSettle();
    expect(selected, '😀');

    await tester.tap(find.byIcon(Icons.backspace_outlined));
    expect(deleted, isTrue);
  });

  testWidgets('lays out without overflow in narrow dark mode', (tester) async {
    AppPreferencesStore.setMockInitialValues({
      'emoji_recent_v1': ['👨‍👩‍👧‍👦', '❤️', '👍🏻'],
    });
    final service = EmojiRecentService(
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
            recentService: service,
            onEmojiSelected: (_) {},
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('👨‍👩‍👧‍👦'), findsOneWidget);
  });
}
