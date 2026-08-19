import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/models/startup_destination.dart';
import 'package:shenliyuan/services/root_page_state_service.dart';

void main() {
  group('HomeInitialTabResolver.initialTabFor', () {
    RestorablePageState rootTab(int index) => RestorablePageState(
          type: RestorablePageType.rootTab,
          arguments: <String, dynamic>{'index': index},
          accountId: 1,
        );

    RestorablePageState chat(int underlying) => RestorablePageState(
          type: RestorablePageType.chat,
          arguments: <String, dynamic>{
            'conversationId': 100,
            'targetUserId': 200,
            'underlyingRootTab': underlying,
          },
          accountId: 1,
        );

    test('home 模式恒为 0，忽略 lastPage', () {
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.home,
          rootTab(3),
        ),
        0,
      );
    });

    test('timetable 模式恒为 2，忽略 lastPage', () {
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.timetable,
          rootTab(1),
        ),
        2,
      );
    });

    test('lastPage + null 回退到 0', () {
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.lastPage,
          null,
        ),
        0,
      );
    });

    test('lastPage + rootTab 读取保存的 index', () {
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.lastPage,
          rootTab(3),
        ),
        3,
      );
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.lastPage,
          rootTab(4),
        ),
        4,
      );
    });

    test('lastPage + rootTab 越界回退到 0', () {
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.lastPage,
          rootTab(5),
        ),
        0,
      );
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.lastPage,
          rootTab(-1),
        ),
        0,
      );
    });

    test('lastPage + chat 读取 underlyingRootTab 打底', () {
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.lastPage,
          chat(3),
        ),
        3,
      );
    });

    test('lastPage + chat 无 underlyingRootTab 回退到 0', () {
      const chatNoUnderlying = RestorablePageState(
        type: RestorablePageType.chat,
        arguments: <String, dynamic>{
          'conversationId': 1,
          'targetUserId': 2,
        },
        accountId: 1,
      );
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.lastPage,
          chatNoUnderlying,
        ),
        0,
      );
    });

    test('lastPage + notification 读取 underlyingRootTab 打底', () {
      const notification = RestorablePageState(
        type: RestorablePageType.notification,
        arguments: <String, dynamic>{'underlyingRootTab': 4},
        accountId: 1,
      );
      expect(
        HomeInitialTabResolver.initialTabFor(
          StartupDestinationMode.lastPage,
          notification,
        ),
        4,
      );
    });
  });
}
