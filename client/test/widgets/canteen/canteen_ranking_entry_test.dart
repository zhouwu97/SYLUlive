import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/canteen_home.dart';
import 'package:shenliyuan/widgets/canteen/canteen_ranking_entry.dart';

Widget _wrap(Widget child, {double width = 180}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('窄宽下排行入口副标题单行截断且无溢出', (tester) async {
    await tester.pumpWidget(
      _wrap(
        CanteenRankingEntryCard(
          entry: const CanteenRankingEntry(
            topId: 1,
            topName: '一食堂二楼',
            topScore: 86,
            total: 3,
          ),
          onTap: () {},
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final subtitle = tester.widget<Text>(find.text('信用加权 · 样本修正'));
    expect(subtitle.maxLines, 1);
    expect(subtitle.overflow, TextOverflow.ellipsis);
  });
}
