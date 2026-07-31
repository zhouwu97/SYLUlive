import 'dart:ui';

const double bottomNavigationSwipeFraction = 1 / 3;
const double pageExitSwipeFraction = 0.3;
const double pageExitSwipeDirectionRatio = 1.2;

bool isBottomNavigationSwipeStart(double startY, double screenHeight) {
  if (screenHeight <= 0) return false;
  return startY >= screenHeight * (1 - bottomNavigationSwipeFraction);
}

bool isUpperContentSwipeStart(double startY, double screenHeight) {
  return !isBottomNavigationSwipeStart(startY, screenHeight);
}

/// Returns -1 for the previous tab, 1 for the next tab, and 0 when ignored.
int horizontalSwipeDirection({
  required Offset start,
  required Offset end,
  required Duration elapsed,
}) {
  final dx = end.dx - start.dx;
  final dy = end.dy - start.dy;
  if (elapsed > const Duration(milliseconds: 360) ||
      dx.abs() <= 90 ||
      dx.abs() <= dy.abs() * 2.4) {
    return 0;
  }
  return dx > 0 ? -1 : 1;
}

bool isLeftPageExitSwipe({
  required Offset start,
  required Offset end,
  required double screenWidth,
}) {
  if (screenWidth <= 0) return false;
  final delta = end - start;
  final requiredDistance = screenWidth * pageExitSwipeFraction;
  return delta.dx <= -requiredDistance &&
      delta.dx.abs() > delta.dy.abs() * pageExitSwipeDirectionRatio;
}
