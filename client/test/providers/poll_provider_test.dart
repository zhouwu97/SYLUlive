import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/poll.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';

Post pollPost({int postId = 1, int pollId = 10, int participants = 0}) {
  final now = DateTime.utc(2026, 7, 18);
  return Post(
    id: postId,
    title: '测试投票',
    content: '说明',
    boardId: 1,
    authorId: 2,
    postType: 'poll',
    contentKind: 'poll',
    createdAt: now,
    pollMeta: PollMeta(
      id: pollId,
      postId: postId,
      category: 'other',
      selectionMode: 'single',
      maxChoices: 1,
      resultsVisibility: 'always',
      allowChange: true,
      status: 'active',
      effectiveStatus: 'active',
      endsAt: now.add(const Duration(days: 1)),
      remainingSeconds: 3600,
      participantCount: participants,
      hasVoted: participants > 0,
      resultsVisible: true,
      canVote: true,
      canChange: participants > 0,
      isOwner: false,
      options: const [
        PollOption(id: 100, text: '选项', sortOrder: 0),
        PollOption(id: 101, text: '另一个选项', sortOrder: 1),
      ],
    ),
  );
}

class FakePollService extends PollService {
  FakePollService() : super(Dio());

  int ballotCalls = 0;
  Completer<Post>? ballotCompleter;
  bool failBallot = false;
  String? lastMineScope;
  String? lastListCursor;
  Completer<PollListResponse>? mineCompleter;

  @override
  Future<PollListResponse> listPolls({
    String sort = 'recommend',
    String category = 'all',
    int page = 1,
    int limit = 20,
    String? cursor,
  }) async {
    lastListCursor = cursor;
    final id = sort == 'latest' ? 2 : 1;
    return PollListResponse(
      items: page == 1 ? [pollPost(postId: id)] : [pollPost(postId: id + 10)],
      page: page,
      limit: 1,
      total: 2,
    );
  }

  @override
  Future<Post> putBallot(int pollId, List<int> optionIds,
      {String? idempotencyKey, PublishSessionScope? session}) async {
    ballotCalls++;
    if (failBallot) {
      throw const PollApiException('poll_ended', '投票已结束');
    }
    if (ballotCompleter != null) return ballotCompleter!.future;
    return pollPost(participants: 1);
  }

  @override
  Future<PollListResponse> listMyPolls(
      {required String scope,
      int page = 1,
      int limit = 20,
      String? cursor}) async {
    lastMineScope = scope;
    if (mineCompleter != null) return mineCompleter!.future;
    return PollListResponse(
        items: [pollPost()], page: page, limit: limit, total: 1);
  }

  @override
  Future<void> deletePoll(int pollId,
      {String? idempotencyKey, PublishSessionScope? session}) async {}
}

/// 记录 createPoll 的请求体与幂等键，用于验证「原样重试」的身份。
class CreateRecordingPollService extends PollService {
  CreateRecordingPollService() : super(Dio());

  final List<String?> keys = <String?>[];
  final List<PollDraft> drafts = <PollDraft>[];
  Object? error;

  @override
  Future<Post> createPoll(PollDraft draft,
      {String? idempotencyKey, PublishSessionScope? session}) async {
    keys.add(idempotencyKey);
    drafts.add(draft);
    if (error != null) throw error!;
    return pollPost();
  }
}

class UpdateRecordingPollService extends PollService {
  UpdateRecordingPollService() : super(Dio());

  final List<String?> keys = <String?>[];

  @override
  Future<Post> updatePoll(int pollId, PollDraft draft,
      {String? idempotencyKey, PublishSessionScope? session}) async {
    keys.add(idempotencyKey);
    throw const PollApiException('poll_unavailable', '服务暂不可用');
  }
}

class SessionRacePollService extends PollService {
  SessionRacePollService() : super(Dio());

  final List<String?> keys = <String?>[];
  final firstRequest = Completer<Post>();
  int calls = 0;

  @override
  Future<Post> createPoll(PollDraft draft,
      {String? idempotencyKey, PublishSessionScope? session}) {
    keys.add(idempotencyKey);
    calls++;
    if (calls == 1) return firstRequest.future;
    throw const PollApiException('poll_unavailable', '服务暂不可用');
  }
}

PollDraft pollDraft({
  String title = '投票标题',
  String description = '说明',
  String category = 'campus_life',
  List<String> options = const ['甲', '乙'],
  List<int> fileIds = const [11, 12],
  DateTime? endsAt,
}) =>
    PollDraft(
      title: title,
      description: description,
      category: category,
      selectionMode: 'single',
      maxChoices: 1,
      resultsVisibility: 'always',
      allowChange: true,
      endsAt: endsAt ?? DateTime.utc(2026, 7, 20, 12),
      options: options,
      fileIds: fileIds,
    );

class RecordingPostProvider extends PostProvider {
  RecordingPostProvider() : super(Dio());

  Post? applied;
  int? removed;

  @override
  void applyExternalPostUpdate(Post updated) => applied = updated;

  @override
  void removeExternalPost(int postId) => removed = postId;
}

class ScriptedPollListService extends PollService {
  ScriptedPollListService(this.pages) : super(Dio());

  final List<PollListResponse> pages;
  final List<int> requestedPages = [];
  final List<String?> requestedCursors = [];

  @override
  Future<PollListResponse> listPolls({
    String sort = 'recommend',
    String category = 'all',
    int page = 1,
    int limit = 20,
    String? cursor,
  }) async {
    requestedPages.add(page);
    requestedCursors.add(cursor);
    return pages[page - 1];
  }
}

PollListResponse _page(int number, List<Post> items,
        {required int total, required bool hasMore, int limit = 20}) =>
    PollListResponse(
      items: items,
      page: number,
      limit: limit,
      total: total,
      matchedTotal: total + 30,
      hasMore: hasMore,
    );

void main() {
  test('翻页只看服务端 has_more：短页仍可继续，未短页也可已到底', () async {
    // 第一页只有 1 条、limit 为 20：按「本页长度等于 limit」猜的旧逻辑会误判为已到底。
    final keepGoing = ScriptedPollListService([
      _page(1, [pollPost(postId: 1)], total: 500, hasMore: true),
      _page(2, [pollPost(postId: 2)], total: 500, hasMore: false),
    ]);
    final provider = PollProvider(keepGoing);
    await provider.load(sort: 'recommend');
    expect(provider.stateFor(sort: 'recommend').hasMore, isTrue);
    await provider.load(sort: 'recommend');
    expect(keepGoing.requestedPages, [1, 2]);
    expect(provider.stateFor(sort: 'recommend').items.map((item) => item.id),
        [1, 2]);

    // 反例：本页刚好满 limit、总数也还更大，但服务端说候选池到此为止，
    // 就不该再按「本页等于 limit」继续猜下一页。
    final stopEarly = ScriptedPollListService([
      _page(1, [pollPost(postId: 1), pollPost(postId: 2)],
          total: 5, hasMore: false, limit: 2),
    ]);
    final stopped = PollProvider(stopEarly);
    await stopped.load(sort: 'recommend');
    expect(stopped.stateFor(sort: 'recommend').hasMore, isFalse);
    await stopped.load(sort: 'recommend');
    expect(stopEarly.requestedPages, [1]);
  });

  test('续页优先使用服务端游标，游标失效时整体替换而不是接着拼', () async {
    final service = ScriptedPollListService([
      PollListResponse(
        items: [pollPost(postId: 1), pollPost(postId: 2)],
        page: 1,
        limit: 2,
        total: 6,
        hasMore: true,
        nextCursor: 'cursor-1',
      ),
      PollListResponse(
        items: [pollPost(postId: 3), pollPost(postId: 4)],
        page: 2,
        limit: 2,
        total: 6,
        hasMore: true,
        nextCursor: 'cursor-2',
      ),
      // 服务端判定游标失效时返回的其实是第一页。
      PollListResponse(
        items: [pollPost(postId: 9)],
        page: 1,
        limit: 2,
        total: 6,
        hasMore: true,
        nextCursor: 'cursor-9',
        cursorStale: true,
      ),
    ]);
    final provider = PollProvider(service);
    await provider.load(sort: 'latest');
    expect(service.requestedCursors, [null]);
    expect(provider.stateFor(sort: 'latest').nextCursor, 'cursor-1');

    // 续页必须把上一页末条的游标带回去，而不是让服务端按 page 猜位置。
    await provider.load(sort: 'latest');
    expect(service.requestedCursors, [null, 'cursor-1']);
    expect(provider.stateFor(sort: 'latest').items.map((item) => item.id),
        [1, 2, 3, 4]);

    await provider.load(sort: 'latest');
    expect(service.requestedCursors.last, 'cursor-2');
    final state = provider.stateFor(sort: 'latest');
    expect(state.items.map((item) => item.id), [9]);
    // 失效后回到第一页：再翻应当从 1 开始，而不是接着 3。
    expect(state.page, 1);
    expect(state.nextCursor, 'cursor-9');
  });
  test('筛选状态隔离且加载更多不重置列表', () async {
    final provider = PollProvider(FakePollService());
    await provider.load(sort: 'recommend');
    await provider.load(sort: 'latest');

    expect(provider.stateFor(sort: 'recommend').items.single.id, 1);
    expect(provider.stateFor(sort: 'latest').items.single.id, 2);

    await provider.load(sort: 'recommend');
    expect(provider.stateFor(sort: 'recommend').items.map((item) => item.id),
        [1, 11]);
    expect(provider.stateFor(sort: 'latest').items.length, 1);
  });

  test('同一投票 mutation 去重并同步全部列表及 PostProvider', () async {
    final service = FakePollService();
    final posts = RecordingPostProvider();
    final provider = PollProvider(service, posts);
    await provider.load(sort: 'recommend');
    await provider.load(sort: 'recommend', category: 'other');

    service.ballotCompleter = Completer<Post>();
    final first = provider.submitBallot(10, [100]);
    final second = provider.submitBallot(10, [100]);
    expect(provider.isMutating(10), isTrue);
    expect(await second, isNull);
    expect(service.ballotCalls, 1);

    final updated = pollPost(participants: 1);
    service.ballotCompleter!.complete(updated);
    expect(await first, updated);
    expect(
        provider
            .stateFor(sort: 'recommend')
            .items
            .single
            .pollMeta
            ?.participantCount,
        1);
    expect(
        provider
            .stateFor(sort: 'recommend', category: 'other')
            .items
            .single
            .pollMeta
            ?.participantCount,
        1);
    expect(posts.applied, updated);
    expect(provider.isMutating(10), isFalse);
  });

  test('投票失败保留原数据并提供稳定错误', () async {
    final service = FakePollService()..failBallot = true;
    final provider = PollProvider(service);
    await provider.load();

    expect(await provider.submitBallot(10, [100]), isNull);
    expect(provider.stateFor().items.single.pollMeta?.participantCount, 0);
    expect(provider.mutationError(10), '投票已结束');
  });

  test('删除从全部列表移除并同步首页缓存', () async {
    final posts = RecordingPostProvider();
    final provider = PollProvider(FakePollService(), posts);
    await provider.load(sort: 'recommend');
    await provider.load(sort: 'recommend', category: 'other');

    expect(await provider.deletePoll(10), isTrue);
    expect(provider.stateFor(sort: 'recommend').items, isEmpty);
    expect(
        provider.stateFor(sort: 'recommend', category: 'other').items, isEmpty);
    expect(posts.removed, 1);
  });

  test('我的投票参与范围使用服务端约定的 voted', () async {
    final service = FakePollService();
    final provider = PollProvider(service);
    await provider.loadMine('voted');
    expect(service.lastMineScope, 'voted');
  });

  test('切换账号会清空我的投票状态', () async {
    final provider = PollProvider(FakePollService());
    provider.syncSessionUser(101);
    await provider.loadMine('created');
    expect(provider.mineState('created').items, isNotEmpty);

    provider.syncSessionUser(202);

    expect(provider.mineState('created').items, isEmpty);
    expect(provider.mineState('created').hasLoaded, isFalse);
  });

  test('同一账号重新登录也会清空带身份的投票状态', () async {
    final provider = PollProvider(FakePollService());
    provider.syncSessionUser(101, 1);
    await provider.loadMine('created');
    expect(provider.mineState('created').items, isNotEmpty);

    provider.syncSessionUser(101, 2);

    expect(provider.mineState('created').items, isEmpty);
    expect(provider.mineState('created').hasLoaded, isFalse);
  });

  test('旧账号投票响应不会覆盖新账号状态', () async {
    final service = FakePollService()
      ..mineCompleter = Completer<PollListResponse>();
    final provider = PollProvider(service);
    provider.syncSessionUser(101);
    final request = provider.loadMine('voted');

    provider.syncSessionUser(202);
    service.mineCompleter!.complete(
      PollListResponse(
        items: [pollPost(postId: 999)],
        page: 1,
        limit: 20,
        total: 1,
      ),
    );
    await request;

    expect(provider.mineState('voted').items, isEmpty);
    expect(provider.mineState('voted').hasLoaded, isFalse);
  });
  group('投票提交的重试身份', () {
    test('草稿指纹覆盖说明、选项、分类、附件和截止时间', () {
      final base = pollDraft();
      for (final changed in [
        pollDraft(description: '改了说明'),
        pollDraft(options: const ['甲', '乙', '丙']),
        pollDraft(category: 'study'),
        pollDraft(fileIds: const [11]),
        pollDraft(endsAt: DateTime.utc(2026, 7, 21, 12)),
        pollDraft(title: '改了标题'),
      ]) {
        expect(changed.fingerprint, isNot(base.fingerprint),
            reason: '内容变化必须算成另一次提交，否则会拿旧键发新请求体');
      }
      expect(pollDraft().fingerprint, base.fingerprint);
    });

    test('同一份草稿原样重试复用同一把幂等键', () async {
      final service = CreateRecordingPollService()
        ..error = const PollApiException('poll_rate_limited', '操作过于频繁');
      final provider = PollProvider(service);
      final draft = pollDraft();

      expect(await provider.createPoll(draft), isNull);
      expect(await provider.createPoll(draft), isNull);

      expect(service.keys, hasLength(2));
      expect(service.keys[0], isNotNull);
      expect(service.keys[1], service.keys[0],
          reason: '原样重试必须是同一次提交，换键只会把冲突换成重复创建');
    });

    test('业务失败保留幂等键，故障恢复后可原样重试', () async {
      final service = CreateRecordingPollService()
        ..error = const PollApiException('poll_unavailable', '服务暂不可用');
      final provider = PollProvider(service);
      final draft = pollDraft();

      await provider.createPoll(draft);
      await provider.createPoll(draft);
      expect(service.keys[1], service.keys[0]);
    });

    test('内容变化后换新键，不拿旧键发新请求体', () async {
      final service = CreateRecordingPollService()
        ..error = const PollApiException('poll_rate_limited', '操作过于频繁');
      final provider = PollProvider(service);

      await provider.createPoll(pollDraft(title: '第一版'));
      await provider.createPoll(pollDraft(title: '改过的第二版'));

      expect(service.keys[0], isNot(service.keys[1]));
    });

    test('更新投票的说明或附件变化也会换新键', () async {
      final service = UpdateRecordingPollService();
      final provider = PollProvider(service);

      await provider.updatePoll(10, pollDraft(description: '第一版说明'));
      await provider.updatePoll(
        10,
        pollDraft(description: '第二版说明', fileIds: const [11]),
      );

      expect(service.keys, hasLength(2));
      expect(service.keys[0], isNot(service.keys[1]));
    });

    test('旧会话成功响应不能清掉新会话正在复用的幂等键', () async {
      final service = SessionRacePollService();
      final provider = PollProvider(service)..syncSessionUser(101, 1);
      final draft = pollDraft();

      final oldRequest = provider.createPoll(draft);
      provider.syncSessionUser(101, 2);
      expect(await provider.createPoll(draft), isNull);

      service.firstRequest.complete(pollPost());
      expect(await oldRequest, isNull);
      expect(await provider.createPoll(draft), isNull);

      expect(service.keys, hasLength(3));
      expect(service.keys[1], isNot(service.keys[0]));
      expect(service.keys[2], service.keys[1],
          reason: '旧会话响应只能结束旧请求，不能删除新会话为同一草稿保存的重试键');
    });

    test('幂等键已不可用时丢弃旧键，下一次点击算新的一次操作', () async {
      final service = CreateRecordingPollService()
        ..error = const PollApiException(
            'idempotency_key_reused', 'Idempotency-Key 已用于不同请求');
      final provider = PollProvider(service);
      final draft = pollDraft();

      await provider.createPoll(draft);
      await provider.createPoll(draft);

      expect(service.keys[0], isNot(service.keys[1]),
          reason: '键已被占用时继续沿用只会让用户卡在同一个冲突里');
      expect(provider.lastActionError, contains('再点一次提交'));
    });

    test('同一请求仍在处理时保留原键，不能另起一次造成重复', () async {
      final service = CreateRecordingPollService()
        ..error = const PollApiException(
            'idempotency_request_in_progress', '相同请求仍在处理中');
      final provider = PollProvider(service);
      final draft = pollDraft();

      await provider.createPoll(draft);
      await provider.createPoll(draft);
      expect(service.keys[1], service.keys[0]);
    });
  });
}
