import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/external_navigator.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/toolbox_screen.dart';

Widget _buildToolboxScreen() {
  return ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(loadOnStart: false),
    child: const MaterialApp(
      home: ToolboxScreen(),
    ),
  );
}

class _ExternalNavigator implements ExternalNavigator {
  _ExternalNavigator(this.opened);

  final bool opened;
  final uris = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    uris.add(uri);
    return opened;
  }
}

void main() {
  for (final opened in [true, false]) {
    testWidgets('融智云考题库导出打开 GitHub Releases：opened=$opened', (tester) async {
      final navigator = _ExternalNavigator(opened);
      ExternalNavigator.register(navigator);
      addTearDown(() =>
          ExternalNavigator.register(const UnsupportedExternalNavigator()));
      await tester.pumpWidget(_buildToolboxScreen());

      expect(find.text('题库导出 · GitHub'), findsOneWidget);
      await tester.ensureVisible(find.text('融智云考'));
      await tester.tap(find.text('融智云考'));
      await tester.pumpAndSettle();

      expect(navigator.uris,
          [Uri.parse('https://github.com/zhouwu97/yunkao/releases')]);
      expect(find.text('无法打开链接'), opened ? findsNothing : findsOneWidget);
      if (!opened) {
        await tester.tap(find.text('融智云考'));
        await tester.pumpAndSettle();
        expect(navigator.uris, hasLength(2));
      }
    });
  }

  testWidgets('网站大全进入独立页面并展示真实网站列表', (tester) async {
    await tester.pumpWidget(_buildToolboxScreen());

    await tester.tap(find.text('网站大全'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.text('省大创平台'), findsOneWidget);
    expect(find.text('教务处'), findsOneWidget);
    expect(find.text('创院'), findsOneWidget);

    for (final title in [
      '查二课',
      '图书馆',
      '沈理就业网',
      '四六级',
      '计算机等级考试',
      '教师资格证',
    ]) {
      await tester.scrollUntilVisible(
        find.text(title),
        240,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text(title), findsOneWidget);
    }
  });
}
