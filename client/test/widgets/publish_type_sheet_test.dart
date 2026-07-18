import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/publish/publish_type_sheet.dart';

void main() {
  testWidgets('发布类型弹层返回投票类型', (tester) async {
    PublishType? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => ElevatedButton(onPressed: () async { result = await PublishTypeSheet.show(context); }, child: const Text('打开')))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发起投票'));
    await tester.pumpAndSettle();
    expect(result, PublishType.poll);
  });
}
