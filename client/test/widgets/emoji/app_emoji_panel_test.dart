import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../lib/services/emoji_recent_service.dart';
import '../../../lib/widgets/emoji/app_emoji_panel.dart';

void main() {
  testWidgets('selects Emoji and exposes complete-character delete action',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = EmojiRecentService(
      preferencesLoader: SharedPreferences.getInstance,
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
    SharedPreferences.setMockInitialValues({
      'emoji_recent_v1': ['👨‍👩‍👧‍👦', '❤️', '👍🏻'],
    });
    final service = EmojiRecentService(
      preferencesLoader: SharedPreferences.getInstance,
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
