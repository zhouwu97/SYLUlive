import 'dart:convert';

import '../platform/contracts/preferences_store.dart';

class CommunityFeedState {
  const CommunityFeedState({
    required this.mode,
    required this.scrollOffset,
  });

  final String mode;
  final double scrollOffset;

  @override
  bool operator ==(Object other) =>
      other is CommunityFeedState &&
      other.mode == mode &&
      other.scrollOffset == scrollOffset;

  @override
  int get hashCode => Object.hash(mode, scrollOffset);
}

class RestorableConversationState {
  const RestorableConversationState({
    required this.accountId,
    required this.conversationId,
    required this.targetUserId,
    required this.targetNickname,
    required this.targetAvatar,
  });

  final int accountId;
  final int conversationId;
  final int targetUserId;
  final String targetNickname;
  final String targetAvatar;

  bool get isValid => accountId > 0 && conversationId > 0 && targetUserId > 0;

  Map<String, Object> toJson() => <String, Object>{
        'accountId': accountId,
        'conversationId': conversationId,
        'targetUserId': targetUserId,
        'targetNickname': targetNickname,
        'targetAvatar': targetAvatar,
      };

  static RestorableConversationState? fromJson(Object? value) {
    if (value is! Map) return null;
    final state = RestorableConversationState(
      accountId: _positiveInt(value['accountId']) ?? 0,
      conversationId: _positiveInt(value['conversationId']) ?? 0,
      targetUserId: _positiveInt(value['targetUserId']) ?? 0,
      targetNickname: value['targetNickname']?.toString() ?? '',
      targetAvatar: value['targetAvatar']?.toString() ?? '',
    );
    return state.isValid ? state : null;
  }

  static int? _positiveInt(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  @override
  bool operator ==(Object other) =>
      other is RestorableConversationState &&
      other.accountId == accountId &&
      other.conversationId == conversationId &&
      other.targetUserId == targetUserId &&
      other.targetNickname == targetNickname &&
      other.targetAvatar == targetAvatar;

  @override
  int get hashCode => Object.hash(
        accountId,
        conversationId,
        targetUserId,
        targetNickname,
        targetAvatar,
      );
}

class RootPageStateStore {
  RootPageStateStore({AppPreferencesStore? preferences})
      : _preferences = preferences;

  static const communityFeedModeKey = 'navigation_community_feed_mode';
  static const communityFeedScrollKey = 'navigation_community_feed_scroll';
  static const conversationKey = 'navigation_last_conversation';
  static final instance = RootPageStateStore();

  final AppPreferencesStore? _preferences;

  Future<CommunityFeedState?> readCommunityFeedState({
    required Set<String> validModes,
  }) async {
    final preferences = _preferences ?? await AppPreferencesStore.getInstance();
    final mode = preferences.getString(communityFeedModeKey);
    final scrollOffset = preferences.getDouble(communityFeedScrollKey);
    if (mode == null ||
        !validModes.contains(mode) ||
        scrollOffset == null ||
        !scrollOffset.isFinite ||
        scrollOffset < 0) {
      return null;
    }
    return CommunityFeedState(mode: mode, scrollOffset: scrollOffset);
  }

  Future<void> saveCommunityFeedState({
    required String mode,
    required double scrollOffset,
  }) async {
    final preferences = _preferences ?? await AppPreferencesStore.getInstance();
    await preferences.setString(communityFeedModeKey, mode);
    await preferences.setDouble(communityFeedScrollKey, scrollOffset);
  }

  Future<RestorableConversationState?> readConversation({
    required int accountId,
  }) async {
    if (accountId <= 0) return null;
    final preferences = _preferences ?? await AppPreferencesStore.getInstance();
    final raw = preferences.getString(conversationKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final state = RestorableConversationState.fromJson(jsonDecode(raw));
      return state?.accountId == accountId ? state : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> saveConversation(RestorableConversationState state) async {
    if (!state.isValid) return;
    final preferences = _preferences ?? await AppPreferencesStore.getInstance();
    await preferences.setString(conversationKey, jsonEncode(state.toJson()));
  }

  Future<void> clearConversation() async {
    final preferences = _preferences ?? await AppPreferencesStore.getInstance();
    await preferences.remove(conversationKey);
  }
}
