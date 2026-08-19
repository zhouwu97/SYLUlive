import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/root_page_state_service.dart';

void main() {
  group('RootPageStateStore lastPage / RestorablePageState', () {
    late MemoryPreferencesStore prefs;
    late RootPageStateStore store;

    setUp(() {
      prefs = MemoryPreferencesStore();
      store = RootPageStateStore(preferences: prefs);
    });

    test('readLastPage returns null when empty', () async {
      final state = await store.readLastPage(accountId: 1);
      expect(state, isNull);
    });

    test('saveLastPage and readLastPage roundtrip for chat', () async {
      const state = RestorablePageState(
        type: RestorablePageType.chat,
        arguments: <String, dynamic>{
          'conversationId': 100,
          'targetUserId': 200,
          'targetNickname': 'Alice',
          'targetAvatar': 'avatar.png',
        },
        accountId: 1,
      );

      await store.saveLastPage(state);
      final read = await store.readLastPage(accountId: 1);

      expect(read, isNotNull);
      expect(read!.type, RestorablePageType.chat);
      expect(read.accountId, 1);
      expect(read.arguments['conversationId'], 100);
      expect(read.arguments['targetUserId'], 200);
      expect(read.arguments['targetNickname'], 'Alice');
      expect(read.arguments['targetAvatar'], 'avatar.png');
    });

    test('saveLastPage and readLastPage roundtrip for rootTab', () async {
      const state = RestorablePageState(
        type: RestorablePageType.rootTab,
        arguments: <String, dynamic>{'index': 2},
        accountId: 1,
      );

      await store.saveLastPage(state);
      final read = await store.readLastPage(accountId: 1);

      expect(read, isNotNull);
      expect(read!.type, RestorablePageType.rootTab);
      expect(read.arguments['index'], 2);
    });

    test('account isolation: User A cannot read User B state', () async {
      const state = RestorablePageState(
        type: RestorablePageType.chat,
        arguments: <String, dynamic>{'conversationId': 100},
        accountId: 1,
      );

      await store.saveLastPage(state);

      final readB = await store.readLastPage(accountId: 2);
      expect(readB, isNull);

      final readA = await store.readLastPage(accountId: 1);
      expect(readA, isNotNull);
      expect(readA!.arguments['conversationId'], 100);
    });

    test('clearLastPage removes the stored page state', () async {
      const state = RestorablePageState(
        type: RestorablePageType.post,
        arguments: <String, dynamic>{'postId': 42},
        accountId: 1,
      );

      await store.saveLastPage(state);
      expect(await store.readLastPage(accountId: 1), isNotNull);

      await store.clearLastPage();
      expect(await store.readLastPage(accountId: 1), isNull);
    });

    test('corrupted JSON returns null gracefully', () async {
      await prefs.setString(RootPageStateStore.lastPageKey, '{invalid_json}');
      final read = await store.readLastPage(accountId: 1);
      expect(read, isNull);
    });
  });
}
