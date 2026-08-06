import 'dart:ui';

enum SwipeAxisIntent {
  pending,
  horizontal,
  vertical,
}

const double mainNavigationGestureZoneHeight = 120.0;
const double pageExitSwipeFraction = 0.3;
const double pageExitSwipeDirectionRatio = 1.2;

bool mainNavigationRequiresBottomZone(int index) {
  return index == 0 || index == 1 || index == 2;
}

bool isMainNavigationGestureZone({
  required double startY,
  required double screenHeight,
}) {
  if (screenHeight <= 0) return false;
  return startY >= screenHeight - mainNavigationGestureZoneHeight;
}

SwipeAxisIntent resolveSwipeAxisIntent({
  required double dx,
  required double dy,
  double slop = 12.0,
  double horizontalRatio = 1.5,
  double verticalRatio = 1.15,
}) {
  final absDx = dx.abs();
  final absDy = dy.abs();

  if (absDx < slop && absDy < slop) {
    return SwipeAxisIntent.pending;
  }
  if (absDx >= slop && absDx >= absDy * horizontalRatio) {
    return SwipeAxisIntent.horizontal;
  }
  if (absDy >= slop && absDy >= absDx * verticalRatio) {
    return SwipeAxisIntent.vertical;
  }
  return SwipeAxisIntent.pending;
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
