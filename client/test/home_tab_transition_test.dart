import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/home_screen.dart';
import 'package:shenliyuan/widgets/home_tab_reveal.dart';

void main() {
  testWidgets('tab reveal item rises from the bottom and settles',
      (tester) async {
    final controller = AnimationController(vsync: tester);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: HomeTabRevealScope(
          animation: controller,
          serial: 1,
          child: const HomeTabRevealItem(
            index: 0,
            child: SizedBox(key: ValueKey('section')),
          ),
        ),
      ),
    );

    final startTransform = tester
        .widgetList<Transform>(find.byType(Transform))
        .firstWhere((widget) => widget.transform.getTranslation().y > 0);
    final fade = tester.widget<Opacity>(find.byType(Opacity));

    expect(startTransform.transform.getTranslation().y, greaterThan(0));
    expect(fade.opacity, lessThan(1));

    controller.value = 1;
    await tester.pump();

    final settledTransform = tester
        .widgetList<Transform>(find.byType(Transform))
        .firstWhere((widget) => widget.transform.getTranslation().y == 0);
    final settledFade = tester.widget<Opacity>(find.byType(Opacity));

    expect(settledTransform.transform.getTranslation().y, 0);
    expect(settledFade.opacity, 1);
  });

  testWidgets('tab stage keeps pages in an IndexedStack', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: HomeTabKeepAliveStage(
          index: 1,
          children: [
            Text('首页'),
            Text('校园'),
          ],
        ),
      ),
    );

    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 1);
    expect(stack.children.length, 2);
  });
}
