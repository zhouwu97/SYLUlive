import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/startup_destination.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/services/root_page_state_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('切换启动模式时 lastPage 状态清理', () {
    const rootTabState = RestorablePageState(
      type: RestorablePageType.rootTab,
      arguments: <String, dynamic>{'index': 3},
      accountId: 1,
    );

    setUp(() {
      // 重置 AppPreferencesStore 单例（mock SharedPreferences）。
      AppPreferencesStore.setMockInitialValues(<String, Object>{
        RootPageStateStore.lastPageKey:
            '{"type":"rootTab","arguments":{"index":3},"accountId":1,"version":1}',
      });
    });

    test('切到 home / timetable 会清除旧的 lastPage，避免日后复活', () async {
      final store = RootPageStateStore();
      expect(await store.readLastPage(accountId: 1), isNotNull);

      final theme = ThemeProvider(loadOnStart: false);
      await theme.setStartupDestination(StartupDestinationMode.home);
      expect(await store.readLastPage(accountId: 1), isNull);

      // 再写入一条，验证切到 timetable 也清除。
      await store.saveLastPage(rootTabState);
      expect(await store.readLastPage(accountId: 1), isNotNull);
      await theme.setStartupDestination(StartupDestinationMode.timetable);
      expect(await store.readLastPage(accountId: 1), isNull);
    });

    test('切到 lastPage 也会清除旧状态（丢弃历史垃圾）', () async {
      final store = RootPageStateStore();
      expect(await store.readLastPage(accountId: 1), isNotNull);

      final theme = ThemeProvider(loadOnStart: false);
      await theme.setStartupDestination(StartupDestinationMode.lastPage);
      expect(await store.readLastPage(accountId: 1), isNull);
    });

    test('顺序执行：切换 lastPage 并写入当前停留 tab，最终正确保留最新停留页面', () async {
      final store = RootPageStateStore();
      // 预置旧的 chat 页面状态
      const oldChatState = RestorablePageState(
        type: RestorablePageType.chat,
        arguments: <String, dynamic>{'conversationId': 99},
        accountId: 1,
      );
      await store.saveLastPage(oldChatState);

      final theme = ThemeProvider(loadOnStart: false);
      // 模拟设置页顺序操作：先 setStartupDestination，再保存当前所在 rootTab
      await theme.setStartupDestination(StartupDestinationMode.lastPage);
      await store.saveLastPage(rootTabState);

      final saved = await store.readLastPage(accountId: 1);
      expect(saved, isNotNull);
      expect(saved!.type, RestorablePageType.rootTab);
      expect(saved.arguments['index'], 3);
    });
  });
}
