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
  });
}
