import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';
import 'package:shenliyuan/widgets/glass_container.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Content extends StatefulWidget {
  const _Content();
  @override
  State<_Content> createState() => _ContentState();
}

class _ContentState extends State<_Content> {
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 260,
        height: 300,
        child: Column(children: [
          const TextField(),
          Expanded(
              child: ListView(controller: scroll, children: [
            for (var i = 0; i < 20; i++)
              SizedBox(height: 48, child: Text('项目 $i')),
          ])),
        ]),
      );
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final kind in [
    'surface',
    'material',
    'card',
    'glass',
    'dialog',
    'alert'
  ]) {
    testWidgets('$kind 切换效果保留内容 State、滚动、焦点和输入草稿', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final appearance = ThemeProvider(loadOnStart: false);
      addTearDown(appearance.dispose);
      const content = _Content();
      final surface = switch (kind) {
        'material' => const AppCardMaterial(child: content),
        'card' => const AppCard(child: content),
        'glass' => const GlassContainer(child: content),
        'dialog' => const AppDialog(child: content),
        'alert' => const AppAlertDialog(content: content),
        _ => AppCardSurface(color: Colors.white, child: content),
      };
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: appearance,
        child: GoldenTestApp(home: Scaffold(body: Center(child: surface))),
      ));
      await tester.pumpAndSettle();
      final state = tester.state<_ContentState>(find.byType(_Content));
      state.scroll.jumpTo(120);
      await tester.enterText(find.byType(TextField), '未发送的草稿');
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.focusNode.hasFocus, isTrue);
      for (final enabled in [true, false, true]) {
        await appearance.setFrostedGlass(enabled);
        await tester.pump();
        expect(tester.state<_ContentState>(find.byType(_Content)), same(state));
        expect(state.scroll.offset, 120);
        expect(find.text('未发送的草稿'), findsOneWidget);
        expect(editable.focusNode.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
