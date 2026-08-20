import 'dart:convert';

import '../platform/contracts/preferences_store.dart';

/// lastPage 持久化协议版本。读取时保留 v1 兼容迁移，未知未来版本直接丢弃。
const int currentRestorablePageStateVersion = 2;
const int _restorableHomeTabCount = 5;

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
  static const lastPageKey = 'startup_last_page_v1';
  static RootPageStateStore instance = RootPageStateStore();

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

  // ── 统一 Last Page 恢复 ──────────────────────────────────────────────

  /// 保存当前可恢复页面状态。仅在 `lastPage` 模式下有意义。
  Future<void> saveLastPage(RestorablePageState state) async {
    final normalized = RestorablePageState.fromJson(state.toJson());
    if (normalized == null) return;
    final preferences = _preferences ?? await AppPreferencesStore.getInstance();
    await preferences.setString(lastPageKey, jsonEncode(normalized.toJson()));
  }

  /// 读取上次退出时的页面状态（账号隔离）。
  Future<RestorablePageState?> readLastPage({
    required int accountId,
  }) async {
    if (accountId <= 0) return null;
    final preferences = _preferences ?? await AppPreferencesStore.getInstance();
    return _readLastPageSync(preferences, accountId);
  }

  /// 同步版本，用于启动路径中偏好已加载的场景。
  RestorablePageState? readLastPageSync(
    AppPreferencesStore preferences, {
    required int accountId,
  }) {
    if (accountId <= 0) return null;
    return _readLastPageSync(preferences, accountId);
  }

  static RestorablePageState? _readLastPageSync(
    AppPreferencesStore preferences,
    int accountId,
  ) {
    final raw = preferences.getString(lastPageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final state = RestorablePageState.fromJson(jsonDecode(raw));
      return state?.accountId == accountId ? state : null;
    } on FormatException {
      return null;
    }
  }

  /// 清除保存的页面状态（退出登录 / 切换模式时调用）。
  Future<void> clearLastPage() async {
    final preferences = _preferences ?? await AppPreferencesStore.getInstance();
    await preferences.remove(lastPageKey);
  }
}

/// 可恢复页面类型。
///
/// 只记录可以安全重建的页面。Modal、BottomSheet、图片查看器等不保存。
enum RestorablePageType {
  rootTab,
  chat,
  post,
  notification,
}

/// 统一的可恢复页面状态。
///
/// 替代旧的 [RestorableConversationState]，支持多种页面类型。
class RestorablePageState {
  const RestorablePageState({
    required this.type,
    required this.arguments,
    required this.accountId,
    this.version = currentRestorablePageStateVersion,
  });

  final RestorablePageType type;
  final Map<String, dynamic> arguments;
  final int accountId;
  final int version;

  bool get isValid => accountId > 0 && _argumentsAreValid(type, arguments);

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type.name,
        'arguments': arguments,
        'accountId': accountId,
        'version': version,
      };

  static RestorablePageState? fromJson(Object? value) {
    if (value is! Map) return null;
    final typeName = value['type']?.toString();
    final type = _parseType(typeName);
    if (type == null) return null;
    final accountId = _positiveInt(value['accountId']);
    if (accountId == null) return null;
    final arguments = value['arguments'];
    final parsedArgs = arguments is Map
        ? Map<String, dynamic>.from(arguments)
        : <String, dynamic>{};
    final version =
        (value['version'] is num) ? (value['version'] as num).toInt() : 1;
    if (version <= 0 || version > currentRestorablePageStateVersion) {
      return null;
    }
    final migratedArgs = _migrateArguments(type, parsedArgs, version);
    if (migratedArgs == null || !_argumentsAreValid(type, migratedArgs)) {
      return null;
    }
    final state = RestorablePageState(
      type: type,
      arguments: migratedArgs,
      accountId: accountId,
      version: currentRestorablePageStateVersion,
    );
    return state.isValid ? state : null;
  }

  static Map<String, dynamic>? _migrateArguments(
    RestorablePageType type,
    Map<String, dynamic> arguments,
    int version,
  ) {
    if (version == currentRestorablePageStateVersion) {
      return Map<String, dynamic>.from(arguments);
    }
    if (version != 1) return null;

    // v1 只调整过字段命名，保留旧 camelCase 与历史 snake_case 两种写法。
    final migrated = Map<String, dynamic>.from(arguments);
    void copyAlias(String current, String legacy) {
      if (!migrated.containsKey(current) && migrated.containsKey(legacy)) {
        migrated[current] = migrated[legacy];
      }
    }

    copyAlias('conversationId', 'conversation_id');
    copyAlias('targetUserId', 'target_user_id');
    copyAlias('targetNickname', 'target_nickname');
    copyAlias('targetAvatar', 'target_avatar');
    copyAlias('postId', 'post_id');
    copyAlias('underlyingRootTab', 'underlying_root_tab');

    // 旧通知状态没有打底 tab 时安全回落到首页。
    if (type == RestorablePageType.notification &&
        !migrated.containsKey('underlyingRootTab')) {
      migrated['underlyingRootTab'] = 0;
    }
    return migrated;
  }

  static bool _argumentsAreValid(
    RestorablePageType type,
    Map<String, dynamic> arguments,
  ) {
    int? readInt(Object? raw) {
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '');
    }

    bool validOptionalRootTab() {
      final raw = arguments['underlyingRootTab'];
      if (raw == null) return true;
      final index = readInt(raw);
      return index != null && index >= 0 && index < _restorableHomeTabCount;
    }

    switch (type) {
      case RestorablePageType.rootTab:
        final index = readInt(arguments['index']);
        return index != null && index >= 0 && index < _restorableHomeTabCount;
      case RestorablePageType.chat:
        final conversationId = readInt(arguments['conversationId']);
        final targetUserId = readInt(arguments['targetUserId']);
        return conversationId != null &&
            conversationId > 0 &&
            targetUserId != null &&
            targetUserId > 0 &&
            validOptionalRootTab();
      case RestorablePageType.post:
        final postId = readInt(arguments['postId']);
        return postId != null && postId > 0 && validOptionalRootTab();
      case RestorablePageType.notification:
        return validOptionalRootTab();
    }
  }

  static RestorablePageType? _parseType(String? name) {
    if (name == null) return null;
    for (final t in RestorablePageType.values) {
      if (t.name == name) return t;
    }
    return null;
  }

  static int? _positiveInt(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  @override
  bool operator ==(Object other) =>
      other is RestorablePageState &&
      other.type == type &&
      other.accountId == accountId &&
      other.version == version &&
      _mapsEqual(other.arguments, arguments);

  @override
  int get hashCode => Object.hash(type, accountId, version);

  static bool _mapsEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
}
