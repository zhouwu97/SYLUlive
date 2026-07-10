import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/competition/competition_batch_selection_bar.dart';

void main() {
  testWidgets('CompetitionBatchSelectionBar basic interactions',
      (WidgetTester tester) async {
    bool selectAllToggled = false;
    bool actionClicked = false;
    bool cancelClicked = false;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompetitionBatchSelectionBar(
          selectedCount: 5,
          allItemsSelected: false,
          allItemsLabel: '全选 (100)',
          onToggleSelectAll: () => selectAllToggled = true,
          onActionClick: () => actionClicked = true,
          onCancel: () => cancelClicked = true,
        ),
      ),
    ));

    expect(find.text('已选 5 项'), findsOneWidget);
    expect(find.text('全选 (100)'), findsOneWidget);

    await tester.tap(find.text('全选 (100)'));
    expect(selectAllToggled, isTrue);

    await tester.tap(find.text('操作'));
    expect(actionClicked, isTrue);

    await tester.tap(find.byIcon(Icons.close));
    expect(cancelClicked, isTrue);
  });
}
