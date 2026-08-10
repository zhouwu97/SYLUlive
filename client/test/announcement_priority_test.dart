import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/home_screen.dart';

void main() {
  group('isModalAnnouncementCandidate（中断语义：只有 urgent 可弹窗）', () {
    test('urgent + modal 是弹窗候选', () {
      expect(
        isModalAnnouncementCandidate(const {
          'priority': 'urgent',
          'display_mode': 'modal',
        }),
        isTrue,
      );
    });

    test('urgent + 空 display_mode（旧数据）是弹窗候选', () {
      expect(
        isModalAnnouncementCandidate(const {'priority': 'urgent'}),
        isTrue,
      );
    });

    test('important 即使标记 modal 也不是弹窗候选', () {
      expect(
        isModalAnnouncementCandidate(const {
          'priority': 'important',
          'display_mode': 'modal',
        }),
        isFalse,
      );
    });

    test('normal 不是弹窗候选', () {
      expect(
        isModalAnnouncementCandidate(const {
          'priority': 'normal',
          'display_mode': 'modal',
        }),
        isFalse,
      );
    });

    test('urgent + banner 不是弹窗候选', () {
      expect(
        isModalAnnouncementCandidate(const {
          'priority': 'urgent',
          'display_mode': 'banner',
        }),
        isFalse,
      );
    });

    test('unknown priority 不是弹窗候选', () {
      expect(
        isModalAnnouncementCandidate(const {
          'priority': 'whatever',
          'display_mode': 'modal',
        }),
        isFalse,
      );
    });
  });
}
