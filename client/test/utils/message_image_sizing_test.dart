import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/message_image_sizing.dart';

void main() {
  const maxW = 260.0;
  const maxH = 320.0;
  const minW = 96.0;

  Size fit(double w, double h) => constrainImageDisplaySize(
        src: Size(w, h),
        maxWidth: maxW,
        maxHeight: maxH,
        minWidth: minW,
      );

  group('constrainImageDisplaySize', () {
    test('1:1 within max box', () {
      final s = fit(1080, 1080);
      expect(s.width, closeTo(260, 0.01));
      expect(s.height, closeTo(260, 0.01));
    });

    test('4:3 keeps landscape ratio (not forced to 4:3 square)', () {
      final s = fit(1080, 810);
      expect(s.width, closeTo(260, 0.01));
      expect(s.height, closeTo(195, 0.01));
      expect(s.width / s.height, closeTo(1080 / 810, 0.01));
    });

    test('3:4 keeps portrait ratio', () {
      final s = fit(1080, 1440);
      expect(s.width, closeTo(1080 * 320 / 1440, 0.01)); // 240
      expect(s.height, closeTo(320, 0.01));
    });

    test('16:9 wide keeps ratio', () {
      final s = fit(1920, 1080);
      expect(s.width, closeTo(260, 0.01));
      expect(s.height, closeTo(146.25, 0.01));
    });

    test('9:16 tall keeps ratio', () {
      final s = fit(1080, 1920);
      expect(s.width, closeTo(180, 0.01));
      expect(s.height, closeTo(320, 0.01));
    });

    test('long screenshot is height-bounded, not full height', () {
      final s = fit(1080, 4000);
      expect(s.height, closeTo(320, 0.01));
      expect(s.width, closeTo(320 * 1080 / 4000, 0.01)); // 86.4
    });

    test('ultra-wide is width-bounded', () {
      final s = fit(4000, 800);
      expect(s.width, closeTo(260, 0.01));
      expect(s.height, closeTo(52, 0.01));
    });

    test('tiny image is not oversized and keeps floor width', () {
      final s = fit(80, 80);
      expect(s.width, closeTo(96, 0.01));
      expect(s.height, closeTo(96, 0.01));
    });

    test('degenerate zero size returns zero', () {
      expect(fit(0, 0), const Size(0, 0));
      expect(fit(0, 100), const Size(0, 0));
    });
  });
}
