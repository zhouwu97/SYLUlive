import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/browsing_history_item.dart';
import 'package:shenliyuan/repositories/browsing_history_repository.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

class MockPreferencesStore implements AppPreferencesStore {
  final Map<String, dynamic> _data = {};

  @override
  String? getString(String key) => _data[key] as String?;

  @override
  Future<bool> setString(String key, String value) async {
    _data[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _data.remove(key);
    return true;
  }

  @override
  bool? getBool(String key) => _data[key] as bool?;
  @override
  Future<bool> setBool(String key, bool value) async {
    _data[key] = value;
    return true;
  }
  @override
  double? getDouble(String key) => _data[key] as double?;
  @override
  Future<bool> setDouble(String key, double value) async {
    _data[key] = value;
    return true;
  }
  @override
  int? getInt(String key) => _data[key] as int?;
  @override
  Future<bool> setInt(String key, int value) async {
    _data[key] = value;
    return true;
  }
  @override
  List<String>? getStringList(String key) => _data[key] as List<String>?;
  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _data[key] = value;
    return true;
  }
  @override
  bool containsKey(String key) => _data.containsKey(key);
  @override
  Set<String> getKeys() => _data.keys.toSet();
  @override
  Future<bool> clear() async {
    _data.clear();
    return true;
  }
  Future<void> reload() async {}
}

void main() {
  group('BrowsingHistoryRepository 单元测试 (Section 43 核心规范)', () {
    late MockPreferencesStore store;
    late BrowsingHistoryRepository repo;

    setUp(() {
      store = MockPreferencesStore();
      repo = BrowsingHistoryRepository(() => store);
    });

    test('进入校园资讯与帖子成功 -> 正常记录', () async {
      await repo.recordVisit(
        targetId: 'news_101',
        type: BrowsingHistoryType.campusNews,
        title: '2026-2027学年开学通知',
      );

      await repo.recordVisit(
        targetId: 'post_202',
        type: BrowsingHistoryType.post,
        title: '自习室推荐',
        author: '张三',
      );

      final all = await repo.getHistory();
      expect(all.length, 2);
      expect(all[0].titleSnapshot, '自习室推荐');
      expect(all[0].type, BrowsingHistoryType.post);
      expect(all[1].titleSnapshot, '2026-2027学年开学通知');
      expect(all[1].type, BrowsingHistoryType.campusNews);
    });

    test('重复打开 -> 不新增记录，更新快照并置顶', () async {
      await repo.recordVisit(
        targetId: 'post_1',
        type: BrowsingHistoryType.post,
        title: '第一篇帖子',
      );

      await repo.recordVisit(
        targetId: 'post_2',
        type: BrowsingHistoryType.post,
        title: '第二篇帖子',
      );

      // 再次访问第一篇帖子
      await repo.recordVisit(
        targetId: 'post_1',
        type: BrowsingHistoryType.post,
        title: '第一篇帖子（新标题）',
      );

      final list = await repo.getHistory();
      expect(list.length, 2); // 保持2条
      expect(list[0].targetId, 'post_1');
      expect(list[0].titleSnapshot, '第一篇帖子（新标题）');
      expect(list[1].targetId, 'post_2');
    });

    test('不同类型相同 ID -> 视作两条不同记录', () async {
      await repo.recordVisit(
        targetId: 'same_id_99',
        type: BrowsingHistoryType.campusNews,
        title: '新闻99',
      );

      await repo.recordVisit(
        targetId: 'same_id_99',
        type: BrowsingHistoryType.post,
        title: '帖子99',
      );

      final list = await repo.getHistory();
      expect(list.length, 2);
      expect(list.any((i) => i.type == BrowsingHistoryType.campusNews), true);
      expect(list.any((i) => i.type == BrowsingHistoryType.post), true);
    });

    test('分类过滤 -> 仅返回指定类型', () async {
      await repo.recordVisit(
        targetId: 'n1',
        type: BrowsingHistoryType.campusNews,
        title: '资讯1',
      );
      await repo.recordVisit(
        targetId: 'p1',
        type: BrowsingHistoryType.post,
        title: '帖子1',
      );

      final newsOnly = await repo.getHistory(filterType: BrowsingHistoryType.campusNews);
      expect(newsOnly.length, 1);
      expect(newsOnly.first.targetId, 'n1');

      final postsOnly = await repo.getHistory(filterType: BrowsingHistoryType.post);
      expect(postsOnly.length, 1);
      expect(postsOnly.first.targetId, 'p1');
    });

    test('删除单条与清空全部', () async {
      await repo.recordVisit(
        targetId: 'item1',
        type: BrowsingHistoryType.post,
        title: '标题1',
      );
      await repo.recordVisit(
        targetId: 'item2',
        type: BrowsingHistoryType.post,
        title: '标题2',
      );

      var list = await repo.getHistory();
      final idToDelete = list.first.id;
      await repo.removeItem(idToDelete);

      list = await repo.getHistory();
      expect(list.length, 1);

      await repo.clearAll();
      list = await repo.getHistory();
      expect(list, isEmpty);
    });

    test('容量上限 500 条 -> 超过自动清理最旧记录', () async {
      for (var i = 1; i <= 510; i++) {
        await repo.recordVisit(
          targetId: 'id_$i',
          type: BrowsingHistoryType.post,
          title: 'Post $i',
        );
      }

      final list = await repo.getHistory();
      expect(list.length, BrowsingHistoryRepository.maxCapacity);
      // 最近访问的应该在最前
      expect(list.first.targetId, 'id_510');
      // 最旧的 1..10 应该被清理
      expect(list.any((i) => i.targetId == 'id_1'), false);
      expect(list.any((i) => i.targetId == 'id_10'), false);
      expect(list.any((i) => i.targetId == 'id_11'), true);
    });

    test('回归测试：用户A浏览历史 -> 切用户B后不得读取A的记录（账号数据隔离）', () async {
      // 用户 A 浏览两条记录
      await repo.recordVisit(
        userId: 'user_A',
        targetId: 'post_A1',
        type: BrowsingHistoryType.post,
        title: '用户A的帖子1',
      );
      await repo.recordVisit(
        userId: 'user_A',
        targetId: 'news_A2',
        type: BrowsingHistoryType.campusNews,
        title: '用户A的新闻2',
      );

      // 用户 B 查询历史 -> 必须为空
      final userBHistoryBefore = await repo.getHistory(userId: 'user_B');
      expect(userBHistoryBefore, isEmpty);

      // 游客查询历史 -> 必须为空
      final guestHistory = await repo.getHistory(userId: null);
      expect(guestHistory, isEmpty);

      // 用户 A 查询历史 -> 正常读取 2 条
      final userAHistory = await repo.getHistory(userId: 'user_A');
      expect(userAHistory.length, 2);
      expect(userAHistory[0].titleSnapshot, '用户A的新闻2');
      expect(userAHistory[1].titleSnapshot, '用户A的帖子1');

      // 用户 B 浏览一条记录
      await repo.recordVisit(
        userId: 'user_B',
        targetId: 'post_B1',
        type: BrowsingHistoryType.post,
        title: '用户B的帖子1',
      );

      // 用户 B 读取历史 -> 仅有 1 条用户 B 自己的记录
      final userBHistoryAfter = await repo.getHistory(userId: 'user_B');
      expect(userBHistoryAfter.length, 1);
      expect(userBHistoryAfter.first.titleSnapshot, '用户B的帖子1');

      // 用户 A 的历史依然保持 2 条，未被污染
      final userAHistoryAgain = await repo.getHistory(userId: 'user_A');
      expect(userAHistoryAgain.length, 2);
      expect(userAHistoryAgain.any((i) => i.titleSnapshot == '用户B的帖子1'), isFalse);
    });
  });
}
