import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/liquid_glass/bottom_nav_controller.dart';

void main() {
  test('拖动状态保留连续位置并记录边界压缩', () {
    final controller = BottomNavController(itemCount: 5, initialIndex: 0);

    controller.beginDrag(0);
    controller.updateDrag(
      rawPosition: 1.5,
      velocityPixelsPerSecond: 180,
    );
    expect(controller.position, 1.5);
    expect(controller.edgeCompression, 0);
    expect(controller.velocity, 180);

    controller.updateDrag(
      rawPosition: -0.25,
      velocityPixelsPerSecond: -600,
    );
    expect(controller.position, 0);
    expect(controller.edgeCompression, greaterThan(0));
    expect(controller.velocity, -600);
  });

  test('慢拖吸附最近入口，快速 flick 只推进一格', () {
    final controller = BottomNavController(itemCount: 5, initialIndex: 0);

    controller.beginDrag(0);
    controller.updateDrag(rawPosition: 1.35, velocityPixelsPerSecond: 50);
    expect(
      controller.endDrag(velocityPixelsPerSecond: 50, itemWidth: 67),
      1,
    );

    controller.beginDrag(1);
    controller.updateDrag(rawPosition: 1.2, velocityPixelsPerSecond: 900);
    expect(
      controller.endDrag(velocityPixelsPerSecond: 900, itemWidth: 67),
      2,
    );
  });
}
