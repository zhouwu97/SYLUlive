import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:shenliyuan/models/publish_image_item.dart';
import 'package:shenliyuan/screens/publish/widgets/publish_image_grid.dart';

PublishImageItem _local(String id) =>
    PublishImageItem.local(XFile('/tmp/$id.jpg'), id);

Widget _grid(
  List<PublishImageItem> images, {
  required void Function(String, String) onReorder,
  bool canAddMore = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: PublishImageGrid(
        images: images,
        canAddMore: canAddMore,
        onAdd: () {},
        onRemove: (_) {},
        onReorder: onReorder,
      ),
    ),
  );
}

void main() {
  testWidgets('拖拽 A 到 C 触发 onReorder(A, C)，Add 槽不参与', (tester) async {
    final reorders = <List<String>>[];
    await tester.pumpWidget(_grid(
      [_local('A'), _local('B'), _local('C')],
      onReorder: (d, t) => reorders.add([d, t]),
    ));
    await tester.pumpAndSettle();

    final centerA = tester.getCenter(find.byKey(const ValueKey('A')));
    final centerC = tester.getCenter(find.byKey(const ValueKey('C')));

    final gesture = await tester.startGesture(centerA);
    await tester.pump(const Duration(milliseconds: 600)); // 长按启动拖动
    await gesture.moveTo(centerC);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(reorders, [
      ['A', 'C'],
    ]);
  });

  testWidgets('Add 槽显示在末尾且不产生拖拽回调', (tester) async {
    final reorders = <List<String>>[];
    await tester.pumpWidget(_grid(
      [_local('A'), _local('B')],
      onReorder: (d, t) => reorders.add([d, t]),
    ));
    await tester.pumpAndSettle();

    // 有 2 图 + 1 个 Add 槽 → 3 个 cell。Add 槽在末尾。
    final addText = find.text('添加照片');
    expect(addText, findsOneWidget);

    // 长按 Add 槽拖动不应触发 reorder（Add 不是可拖拽项）。
    final addCenter = tester.getCenter(addText);
    final gesture = await tester.startGesture(addCenter);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('A'))));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(reorders, isEmpty);
  });

  testWidgets('达到上限时不显示 Add 槽', (tester) async {
    await tester.pumpWidget(_grid(
      [_local('A'), _local('B'), _local('C')],
      onReorder: (d, t) {},
      canAddMore: false,
    ));
    await tester.pumpAndSettle();

    expect(find.text('添加照片'), findsNothing);
  });
}
