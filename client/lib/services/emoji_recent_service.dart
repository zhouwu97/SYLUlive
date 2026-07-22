import 'package:shenliyuan/platform/contracts/preferences_store.dart';


/// 共享的最近使用 Emoji 存储，不区分私信和评论页面。
class EmojiRecentService {
  EmojiRecentService({
    Future<AppPreferencesStore> Function()? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? AppPreferencesStore.getInstance;

  static final EmojiRecentService instance = EmojiRecentService();

  static const String _storageKey = 'emoji_recent_v1';
  static const int maxRecentCount = 32;

  final Future<AppPreferencesStore> Function() _preferencesLoader;
  Future<AppPreferencesStore>? _loadingPreferences;
  List<String>? _cache;

  Future<AppPreferencesStore> get _preferences =>
      _loadingPreferences ??= _preferencesLoader();

  Future<List<String>> load() async {
    final cached = _cache;
    if (cached != null) return List.unmodifiable(cached);
    final preferences = await _preferences;
    _cache = preferences.getStringList(_storageKey) ?? <String>[];
    return List.unmodifiable(_cache!);
  }

  Future<void> record(String emoji) async {
    if (emoji.isEmpty) return;
    final current = await load();
    final next = <String>[emoji, ...current.where((item) => item != emoji)];
    _cache = next.take(maxRecentCount).toList(growable: false);
    final preferences = await _preferences;
    await preferences.setStringList(_storageKey, _cache!);
  }
}
