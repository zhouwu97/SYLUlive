import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/screen_swipe.dart';

void main() {
  test('bottom third is reserved for main navigation swipes', () {
    expect(isBottomNavigationSwipeStart(650, 900), isTrue);
    expect(isBottomNavigationSwipeStart(599, 900), isFalse);
  });

  test('detects a fast horizontal swipe direction', () {
    expect(
      horizontalSwipeDirection(
        start: const Offset(320, 700),
        end: const Offset(220, 710),
        elapsed: const Duration(milliseconds: 220),
      ),
      1,
    );
    expect(
      horizontalSwipeDirection(
        start: const Offset(120, 700),
        end: const Offset(220, 690),
        elapsed: const Duration(milliseconds: 220),
      ),
      -1,
    );
  });

  test('ignores vertical or slow gestures', () {
    expect(
      horizontalSwipeDirection(
        start: const Offset(200, 700),
        end: const Offset(270, 820),
        elapsed: const Duration(milliseconds: 220),
      ),
      0,
    );
    expect(
      horizontalSwipeDirection(
        start: const Offset(300, 700),
        end: const Offset(200, 700),
        elapsed: const Duration(milliseconds: 600),
      ),
      0,
    );
  });

  testWidgets('upper and lower swipe zones do not trigger each other',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var navigationSwitches = 0;
    var contentSwitches = 0;
    Offset? navigationStart;
    DateTime? navigationStartTime;
    double? contentStartY;

    await tester.pumpWidget(
      MaterialApp(
        home: Listener(
          onPointerDown: (event) {
            if (isBottomNavigationSwipeStart(event.position.dy, 900)) {
              navigationStart = event.position;
              navigationStartTime = DateTime.now();
            }
          },
          onPointerUp: (event) {
            if (navigationStart == null || navigationStartTime == null) return;
            final direction = horizontalSwipeDirection(
              start: navigationStart!,
              end: event.position,
              elapsed: DateTime.now().difference(navigationStartTime!),
            );
            navigationStart = null;
            navigationStartTime = null;
            if (direction != 0) navigationSwitches++;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (details) {
              contentStartY = details.globalPosition.dy;
            },
            onHorizontalDragEnd: (_) {
              if (contentStartY != null &&
                  !isBottomNavigationSwipeStart(contentStartY!, 900)) {
                contentSwitches++;
              }
              contentStartY = null;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    await tester.dragFrom(
      const Offset(320, 750),
      const Offset(-100, 0),
    );
    await tester.pump();
    expect(navigationSwitches, 1);
    expect(contentSwitches, 0);

    await tester.dragFrom(
      const Offset(320, 300),
      const Offset(-100, 0),
    );
    await tester.pump();
    expect(navigationSwitches, 1);
    expect(contentSwitches, 1);
  });
}
