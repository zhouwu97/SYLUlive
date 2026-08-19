import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/home_screen.dart';
import 'package:shenliyuan/utils/tab_transition_ledger.dart';
import 'package:shenliyuan/widgets/home_tab_reveal.dart';

void main() {
  test('帖子首屏完成后才开始更新检查', () async {
    final feedCompleter = Completer<void>();
    var updateCheckStarted = false;

    final startup = loadInitialFeedBeforeUpdateCheck(
      loadInitialFeed: () => feedCompleter.future,
      initializeUpdateCheck: () async {
        updateCheckStarted = true;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(updateCheckStarted, isFalse);

    feedCompleter.complete();
    await startup;
    expect(updateCheckStarted, isTrue);
  });

  test('帖子首屏失败后仍执行更新检查', () async {
    var updateCheckStarted = false;

    await loadInitialFeedBeforeUpdateCheck(
      loadInitialFeed: () => Future<void>.error(StateError('load failed')),
      initializeUpdateCheck: () async {
        updateCheckStarted = true;
      },
    );

    expect(updateCheckStarted, isTrue);
  });

  test('root tab ledger rejects stale A→B→C completions and cancels safely',
      () {
    final ledger = TabTransitionLedger(itemCount: 5, initialIndex: 0);
    final a = ledger.begin(1, commit: true, visualStart: 0);
    final b = ledger.begin(2, commit: true, visualStart: 0.4);
    final c = ledger.begin(3, commit: true, visualStart: 1.2);

    expect(ledger.visitedTabs, containsAll(<int>[0, 1, 2, 3]));
    expect(ledger.currentIndex, 3);
    expect(ledger.complete(a), isFalse);
    expect(ledger.complete(b), isFalse);
    expect(ledger.complete(c), isTrue);
    expect(ledger.currentIndex, 3);
    expect(ledger.targetIndex, isNull);
    expect(ledger.revealedTabs, containsAll(<int>[0, 3]));
    expect(ledger.revealedTabs, isNot(contains(1)));
    expect(ledger.revealedTabs, isNot(contains(2)));

    // 重复点击当前 Tab 或取消一个未提交的手势，都不能把最终状态改回旧页。
    ledger.cancel();
    final cancelPlan = ledger.begin(2, commit: false, visualStart: 2.5);
    ledger.cancel();
    expect(ledger.complete(cancelPlan), isFalse);
    expect(ledger.currentIndex, 3);
    expect(ledger.visualIndex, 3);
    expect(ledger.targetIndex, isNull);
  });

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

    expect(startTransform.transform.getTranslation().y, 8);
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

  testWidgets('late mounted reveal item skips a completed first reveal',
      (tester) async {
    final controller = AnimationController(vsync: tester);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: HomeTabRevealScope(
          animation: controller,
          serial: 1,
          child: const SizedBox(key: ValueKey('initial')),
        ),
      ),
    );
    controller.value = 1;
    await tester.pump();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: HomeTabRevealScope(
          animation: controller,
          serial: 1,
          child: const HomeTabRevealItem(
            index: 0,
            child: SizedBox(key: ValueKey('late-item')),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('late-item')), findsOneWidget);
    expect(find.byType(Transform), findsNothing);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('reduced motion keeps opacity feedback and removes movement',
      (tester) async {
    final controller = AnimationController(vsync: tester);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: HomeTabRevealScope(
            animation: controller,
            serial: 1,
            child: const HomeTabRevealItem(
              index: 0,
              child: SizedBox(key: ValueKey('reduced-item')),
            ),
          ),
        ),
      ),
    );
    controller.value = 0.5;
    await tester.pump();

    expect(find.byType(Opacity), findsOneWidget);
    expect(find.byType(Transform), findsNothing);
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
