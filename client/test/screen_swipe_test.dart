import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/screen_swipe.dart';
import 'package:shenliyuan/widgets/swipe_to_exit.dart';

class _NavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> poppedRoutes = [];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    poppedRoutes.add(route);
    super.didPop(route, previousRoute);
  }
}

void main() {
  test('main navigation gesture zone is bottom 120dp of screen', () {
    expect(
      isMainNavigationGestureZone(startY: 800, screenHeight: 900),
      isTrue,
    );
    expect(
      isMainNavigationGestureZone(startY: 700, screenHeight: 900),
      isFalse,
    );
  });

  group('resolveSwipeAxisIntent', () {
    test('slop threshold returns pending for small movements', () {
      expect(
        resolveSwipeAxisIntent(dx: 5, dy: 4),
        SwipeAxisIntent.pending,
      );
    });

    test('horizontal movement triggers horizontal intent', () {
      expect(
        resolveSwipeAxisIntent(dx: 30, dy: 5),
        SwipeAxisIntent.horizontal,
      );
      expect(
        resolveSwipeAxisIntent(dx: 100, dy: 20),
        SwipeAxisIntent.horizontal,
      );
    });

    test('vertical movement triggers vertical intent', () {
      expect(
        resolveSwipeAxisIntent(dx: 10, dy: 40),
        SwipeAxisIntent.vertical,
      );
      expect(
        resolveSwipeAxisIntent(dx: 25, dy: 100),
        SwipeAxisIntent.vertical,
      );
    });

    test('ambiguous diagonal movement remains pending', () {
      expect(
        resolveSwipeAxisIntent(dx: 20, dy: 18),
        SwipeAxisIntent.pending,
      );
    });
  });

  test('detects a fast horizontal swipe direction', () {
    expect(
      horizontalSwipeDirection(
        start: const Offset(320, 700),
        end: const Offset(210, 710),
        elapsed: const Duration(milliseconds: 220),
      ),
      1,
    );
    expect(
      horizontalSwipeDirection(
        start: const Offset(120, 700),
        end: const Offset(230, 690),
        elapsed: const Duration(milliseconds: 220),
      ),
      -1,
    );
  });

  test('ignores short horizontal gestures', () {
    expect(
      horizontalSwipeDirection(
        start: const Offset(200, 700),
        end: const Offset(280, 704),
        elapsed: const Duration(milliseconds: 180),
      ),
      0,
    );
  });

  test('ignores vertical or slow gestures', () {
    expect(
      horizontalSwipeDirection(
        start: const Offset(200, 700),
        end: const Offset(310, 820),
        elapsed: const Duration(milliseconds: 220),
      ),
      0,
    );
    expect(
      horizontalSwipeDirection(
        start: const Offset(300, 700),
        end: const Offset(190, 700),
        elapsed: const Duration(milliseconds: 420),
      ),
      0,
    );
  });

  test('ignores diagonal gestures with too much vertical drift', () {
    expect(
      horizontalSwipeDirection(
        start: const Offset(300, 700),
        end: const Offset(190, 750),
        elapsed: const Duration(milliseconds: 220),
      ),
      0,
    );
  });

  group('left page exit swipe', () {
    test('accepts a deliberate left swipe over thirty percent of the screen',
        () {
      expect(
        isLeftPageExitSwipe(
          start: const Offset(360, 420),
          end: const Offset(180, 426),
          screenWidth: 400,
        ),
        isTrue,
      );
    });

    test('ignores shorter left swipes', () {
      expect(
        isLeftPageExitSwipe(
          start: const Offset(360, 420),
          end: const Offset(245, 420),
          screenWidth: 400,
        ),
        isFalse,
      );
    });

    test('ignores rightward and strongly diagonal swipes', () {
      expect(
        isLeftPageExitSwipe(
          start: const Offset(40, 420),
          end: const Offset(240, 420),
          screenWidth: 400,
        ),
        isFalse,
      );
      expect(
        isLeftPageExitSwipe(
          start: const Offset(360, 300),
          end: const Offset(180, 460),
          screenWidth: 400,
        ),
        isFalse,
      );
    });

    test('accepts a naturally diagonal left swipe', () {
      expect(
        isLeftPageExitSwipe(
          start: const Offset(340, 300),
          end: const Offset(190, 390),
          screenWidth: 400,
        ),
        isTrue,
      );
    });
  });

  testWidgets('page exits only after a deliberate left swipe', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const SwipeToExit(
                      child: Scaffold(body: Text('私信')),
                    ),
                  ),
                );
              },
              child: const Text('进入私信'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('进入私信'));
    await tester.pumpAndSettle();
    final swipeWidget = find.byType(SwipeToExit);
    final pageWidth = tester.getSize(swipeWidget).width;
    final mediaWidth = MediaQuery.sizeOf(tester.element(swipeWidget)).width;
    final swipeStart = Offset(pageWidth - 40, 400);

    await tester.dragFrom(swipeStart, Offset(-mediaWidth * 0.29, 0));
    await tester.pumpAndSettle();
    expect(find.text('私信'), findsOneWidget);

    await tester.dragFrom(swipeStart, Offset(-mediaWidth * 0.31, 0));
    await tester.pumpAndSettle();
    expect(find.text('进入私信'), findsOneWidget);
    expect(find.text('私信'), findsNothing);
  });

  testWidgets('mouse drag can exit a page in the Android emulator',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final navigatorObserver = _NavigatorObserver();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [navigatorObserver],
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const SwipeToExit(
                      child: Scaffold(body: Text('私信')),
                    ),
                  ),
                );
              },
              child: const Text('进入私信'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('进入私信'));
    await tester.pumpAndSettle();

    final swipeWidget = find.byType(SwipeToExit);
    final pageWidth = tester.getSize(swipeWidget).width;
    final mediaWidth = MediaQuery.sizeOf(tester.element(swipeWidget)).width;
    final gesture = await tester.startGesture(
      Offset(pageWidth - 40, 400),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(Offset(-mediaWidth * 0.35, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(navigatorObserver.poppedRoutes, hasLength(1));
    expect(find.text('私信'), findsNothing);
  });

  testWidgets(
      'main navigation zone and content swipe zone do not trigger each other',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var navigationSwitches = 0;
    var contentSwitches = 0;
    Offset? navigationStart;
    DateTime? navigationStartTime;
    SwipeAxisIntent navigationIntent = SwipeAxisIntent.pending;
    double? contentStartY;

    await tester.pumpWidget(
      MaterialApp(
        home: Listener(
          onPointerDown: (event) {
            if (isMainNavigationGestureZone(
              startY: event.position.dy,
              screenHeight: 900,
            )) {
              navigationStart = event.position;
              navigationStartTime = DateTime.now();
              navigationIntent = SwipeAxisIntent.pending;
            }
          },
          onPointerMove: (event) {
            if (navigationStart == null) return;
            if (navigationIntent == SwipeAxisIntent.pending) {
              navigationIntent = resolveSwipeAxisIntent(
                dx: event.position.dx - navigationStart!.dx,
                dy: event.position.dy - navigationStart!.dy,
              );
            }
          },
          onPointerUp: (event) {
            if (navigationStart == null || navigationStartTime == null) return;
            final isHorizontal = navigationIntent == SwipeAxisIntent.horizontal;
            navigationStart = null;
            navigationStartTime = null;
            navigationIntent = SwipeAxisIntent.pending;
            if (isHorizontal) navigationSwitches++;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (details) {
              contentStartY = details.globalPosition.dy;
            },
            onHorizontalDragEnd: (_) {
              if (contentStartY != null &&
                  !isMainNavigationGestureZone(
                    startY: contentStartY!,
                    screenHeight: 900,
                  )) {
                contentSwitches++;
              }
              contentStartY = null;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    // Swipe in bottom navigation priority zone (y = 820)
    await tester.dragFrom(
      const Offset(320, 820),
      const Offset(-100, 0),
    );
    await tester.pump();
    expect(navigationSwitches, 1);
    expect(contentSwitches, 0);

    // Swipe in content zone (y = 500)
    await tester.dragFrom(
      const Offset(320, 500),
      const Offset(-100, 0),
    );
    await tester.pump();
    expect(navigationSwitches, 1);
    expect(contentSwitches, 1);
  });

  testWidgets(
      'vertical scroll with diagonal drift does not trigger navigation switch',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var navigationSwitches = 0;
    Offset? startPos;
    SwipeAxisIntent intent = SwipeAxisIntent.pending;

    await tester.pumpWidget(
      MaterialApp(
        home: Listener(
          onPointerDown: (event) {
            startPos = event.position;
            intent = SwipeAxisIntent.pending;
          },
          onPointerMove: (event) {
            if (startPos == null || intent == SwipeAxisIntent.vertical) return;
            if (intent == SwipeAxisIntent.pending) {
              intent = resolveSwipeAxisIntent(
                dx: event.position.dx - startPos!.dx,
                dy: event.position.dy - startPos!.dy,
              );
            }
          },
          onPointerUp: (event) {
            if (intent == SwipeAxisIntent.horizontal) {
              navigationSwitches++;
            }
            startPos = null;
            intent = SwipeAxisIntent.pending;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );

    // Fast upward scroll with horizontal drift (dx = -25, dy = -200)
    await tester.dragFrom(const Offset(300, 750), const Offset(-25, -200));
    await tester.pump();
    expect(navigationSwitches, 0);

    // Downward scroll with horizontal drift (dx = 25, dy = 220)
    await tester.dragFrom(const Offset(300, 750), const Offset(25, 220));
    await tester.pump();
    expect(navigationSwitches, 0);
  });

  test(
      'tab priority rules restrict index 0, 1, 2 to bottom 120dp zone and allow index 3, 4 full-screen',
      () {
    bool canStartMainNavigationSwipe(
      int currentIndex,
      Offset position,
      double screenHeight,
    ) {
      if (currentIndex == 0 || currentIndex == 1 || currentIndex == 2) {
        return isMainNavigationGestureZone(
          startY: position.dy,
          screenHeight: screenHeight,
        );
      }
      return true;
    }

    const screenHeight = 900.0;
    const contentOffset = Offset(200, 500);
    const bottomNavOffset = Offset(200, 820);

    // Index 0 (Shuitie): content area false, bottom nav area true
    expect(
        canStartMainNavigationSwipe(0, contentOffset, screenHeight), isFalse);
    expect(
        canStartMainNavigationSwipe(0, bottomNavOffset, screenHeight), isTrue);

    // Index 1 (Market): content area false, bottom nav area true
    expect(
        canStartMainNavigationSwipe(1, contentOffset, screenHeight), isFalse);
    expect(
        canStartMainNavigationSwipe(1, bottomNavOffset, screenHeight), isTrue);

    // Index 2 (CourseSchedule): content area false, bottom nav area true
    expect(
        canStartMainNavigationSwipe(2, contentOffset, screenHeight), isFalse);
    expect(
        canStartMainNavigationSwipe(2, bottomNavOffset, screenHeight), isTrue);

    // Index 3 (Campus): full-screen candidate (content area true, bottom nav area true)
    expect(canStartMainNavigationSwipe(3, contentOffset, screenHeight), isTrue);
    expect(
        canStartMainNavigationSwipe(3, bottomNavOffset, screenHeight), isTrue);

    // Index 4 (Profile): full-screen candidate (content area true, bottom nav area true)
    expect(canStartMainNavigationSwipe(4, contentOffset, screenHeight), isTrue);
    expect(
        canStartMainNavigationSwipe(4, bottomNavOffset, screenHeight), isTrue);
  });
}
