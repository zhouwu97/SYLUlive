import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/home_screen.dart';
import 'package:shenliyuan/widgets/home_tab_reveal.dart';

void main() {
  double revealTranslationY(WidgetTester tester, Key childKey) {
    final transforms = tester.widgetList<Transform>(
      find.ancestor(
        of: find.byKey(childKey),
        matching: find.byType(Transform),
      ),
    );
    return transforms
        .map((widget) => widget.transform.getTranslation().y)
        .firstWhere((dy) => dy > 0, orElse: () => 0);
  }

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

    expect(startTransform.transform.getTranslation().y, 56);
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

  testWidgets('tab reveal items rise with staggered display order',
      (tester) async {
    final controller = AnimationController(vsync: tester);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: HomeTabRevealScope(
          animation: controller,
          serial: 1,
          child: const Column(
            children: [
              HomeTabRevealItem(
                index: 0,
                revealOrder: 0,
                child: SizedBox(key: ValueKey('first-card')),
              ),
              HomeTabRevealItem(
                index: 1,
                revealOrder: 2,
                child: SizedBox(key: ValueKey('later-card')),
              ),
            ],
          ),
        ),
      ),
    );

    controller.value = 0.1;
    await tester.pump();

    final firstY = revealTranslationY(tester, const ValueKey('first-card'));
    final laterY = revealTranslationY(tester, const ValueKey('later-card'));

    expect(firstY, greaterThan(0));
    expect(firstY, lessThan(laterY));

    controller.value = 1;
    await tester.pump();

    expect(revealTranslationY(tester, const ValueKey('first-card')), 0);
    expect(revealTranslationY(tester, const ValueKey('later-card')), 0);
    for (final opacity in tester.widgetList<Opacity>(find.byType(Opacity))) {
      expect(opacity.opacity, 1);
    }
  });

  testWidgets('non-post header stays outside reveal item and does not move',
      (tester) async {
    final controller = AnimationController(vsync: tester);
    addTearDown(controller.dispose);
    const searchKey = ValueKey('search-bar');

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: HomeTabRevealScope(
          animation: controller,
          serial: 1,
          child: const Column(
            children: [
              SizedBox(key: searchKey, height: 44, child: Text('搜索栏')),
              HomeTabRevealItem(
                index: 0,
                child: SizedBox(key: ValueKey('post-card')),
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      find.ancestor(
        of: find.byKey(searchKey),
        matching: find.byType(HomeTabRevealItem),
      ),
      findsNothing,
    );

    final startTop = tester.getTopLeft(find.byKey(searchKey));
    controller.value = 0.5;
    await tester.pump();
    final animatedTop = tester.getTopLeft(find.byKey(searchKey));

    expect(animatedTop.dy, startTop.dy);
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
