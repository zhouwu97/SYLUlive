import 'package:shared_preferences/shared_preferences.dart';

/// 共享的最近使用 Emoji 存储，不区分私信和评论页面。
class EmojiRecentService {
  EmojiRecentService({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static final EmojiRecentService instance = EmojiRecentService();

  static const String _storageKey = 'emoji_recent_v1';
  static const int maxRecentCount = 32;

  final Future<SharedPreferences> Function() _preferencesLoader;
  Future<SharedPreferences>? _loadingPreferences;
  List<String>? _cache;

  Future<SharedPreferences> get _preferences =>
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
