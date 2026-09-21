import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_asset_ref.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  test('Unicode 按完整字素识别肤色、ZWJ 和旗帜，不拆分普通文字', () {
    expect(
        EmojiRecentManager.unicodeIn('你好 👩🏽‍💻 🇨🇳 1️⃣ 😀')
            .map((e) => e.assetKey),
        ['unicode:👩🏽‍💻', 'unicode:🇨🇳', 'unicode:1️⃣', 'unicode:😀']);
  });
  test('旧数据只被首个账号认领，切换账号和重启保持隔离', () async {
    final prefs = MemoryPreferencesStore();
    await prefs.setStringList('emoji_recent_v1', ['😀']);
    final manager = EmojiRecentManager(preferencesLoader: () async => prefs);
    manager.switchUser('1');
    expect((await manager.load()).single.assetKey, 'unicode:😀');
    manager.switchUser('2');
    expect(await manager.load(), isEmpty);
    final restarted = EmojiRecentManager(preferencesLoader: () async => prefs)
      ..switchUser('1');
    expect((await restarted.load()).single.assetKey, 'unicode:😀');
    restarted.switchUser(null);
    expect(await restarted.load(), isEmpty);
  });

  test('登录之后产生的新匿名使用会被下一个账号认领', () async {
    final prefs = MemoryPreferencesStore();
    final manager = EmojiRecentManager(preferencesLoader: () async => prefs);
    // 第一次匿名使用，随后登录 A：这一批归 A。
    await manager.recordSent(const EmojiAssetRef(assetKey: 'unicode:😀'),
        accountId: null);
    manager.switchUser('1');
    expect((await manager.load()).single.assetKey, 'unicode:😀');

    // A 退出后继续匿名使用，再登录 B：新会话的数据必须能认领，
    // 早期实现的全局 claimed_by 会让它永远留在本机。
    manager.switchUser(null);
    expect(await manager.load(), isEmpty);
    await manager.recordSent(const EmojiAssetRef(assetKey: 'unicode:😃'),
        accountId: null);
    manager.switchUser('2');
    final keys = (await manager.load()).map((e) => e.assetKey).toList();
    expect(keys, contains('unicode:😃'));
    // 已经归 A 的那批不能又被 B 认领一次。
    expect(keys, isNot(contains('unicode:😀')));
  });

  test('并发记录不丢计数，重复合并不膨胀，清空阻止旧数据复活', () async {
    final prefs = MemoryPreferencesStore();
    final manager = EmojiRecentManager(preferencesLoader: () async => prefs)
      ..switchUser('1');
    await manager.load();
    await Future.wait(List.generate(
        20,
        (_) => manager.recordSent(const EmojiAssetRef(assetKey: 'unicode:😀'),
            accountId: '1')));
    final snapshot = await manager.load();
    expect(snapshot.single.useCount, 20);
    await manager.merge(snapshot);
    await manager.merge(snapshot);
    expect((await manager.load()).single.useCount, 20);
    await manager.clear();
    await manager.merge(snapshot);
    expect(await manager.load(), isEmpty);
  });

  test('请求完成时仍写原账号，并且只保留最近一百项', () async {
    final prefs = MemoryPreferencesStore();
    final manager = EmojiRecentManager(preferencesLoader: () async => prefs)
      ..switchUser('1');
    await manager.load();
    final write = manager.recordBatchSent(
        List.generate(110, (i) => EmojiAssetRef(assetKey: 'private:$i')),
        accountId: '1');
    manager.switchUser('2');
    await write;
    expect(await manager.load(), isEmpty);
    manager.switchUser('1');
    expect(await manager.load(), hasLength(100));
  });
}
