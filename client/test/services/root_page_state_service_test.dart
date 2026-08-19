import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/root_page_state_service.dart';

void main() {
  test('恢复社区信息流模式和有效滚动位置', () async {
    final preferences = MemoryPreferencesStore();
    final store = RootPageStateStore(preferences: preferences);

    await store.saveCommunityFeedState(
      mode: 'featured',
      scrollOffset: 428.5,
    );

    expect(
      await store.readCommunityFeedState(
        validModes: const {'time', 'all', 'featured', 'following'},
      ),
      const CommunityFeedState(mode: 'featured', scrollOffset: 428.5),
    );

    await store.saveCommunityFeedState(
      mode: 'unknown',
      scrollOffset: double.infinity,
    );
    expect(
      await store.readCommunityFeedState(
        validModes: const {'time', 'all', 'featured', 'following'},
      ),
      isNull,
    );
  });

  test('私信会话仅向同一账号恢复且不保存消息正文', () async {
    final preferences = MemoryPreferencesStore();
    final store = RootPageStateStore(preferences: preferences);
    const state = RestorableConversationState(
      accountId: 7,
      conversationId: 31,
      targetUserId: 9,
      targetNickname: '同学',
      targetAvatar: '/avatar.png',
    );

    await store.saveConversation(state);

    expect(await store.readConversation(accountId: 7), state);
    expect(await store.readConversation(accountId: 8), isNull);
    expect(
      preferences
          .getString(RootPageStateStore.conversationKey)
          ?.contains('message'),
      isFalse,
    );

    await store.clearConversation();
    expect(await store.readConversation(accountId: 7), isNull);
  });
}
