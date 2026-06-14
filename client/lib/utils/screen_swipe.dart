import 'dart:ui';

const double bottomNavigationSwipeFraction = 1 / 3;

bool isBottomNavigationSwipeStart(double startY, double screenHeight) {
  if (screenHeight <= 0) return false;
  return startY >= screenHeight * (1 - bottomNavigationSwipeFraction);
}

/// Returns -1 for the previous tab, 1 for the next tab, and 0 when ignored.
int horizontalSwipeDirection({
  required Offset start,
  required Offset end,
  required Duration elapsed,
}) {
  final dx = end.dx - start.dx;
  final dy = end.dy - start.dy;
  if (elapsed > const Duration(milliseconds: 400) ||
      dx.abs() <= 60 ||
      dx.abs() <= dy.abs() * 2) {
    return 0;
  }
  return dx > 0 ? -1 : 1;
}
