import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/poll.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/services/poll_service.dart';

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
  Completer<PollListResponse>? mineCompleter;

  @override
  Future<PollListResponse> listPolls({
    String sort = 'recommend',
    String category = 'all',
    int page = 1,
    int limit = 20,
  }) async {
    final id = sort == 'latest' ? 2 : 1;
    return PollListResponse(
      items: page == 1 ? [pollPost(postId: id)] : [pollPost(postId: id + 10)],
      page: page,
      limit: 1,
      total: 2,
    );
  }

  @override
  Future<Post> putBallot(int pollId, List<int> optionIds) async {
    ballotCalls++;
    if (failBallot) {
      throw const PollApiException('poll_ended', '投票已结束');
    }
    if (ballotCompleter != null) return ballotCompleter!.future;
    return pollPost(participants: 1);
  }

  @override
  Future<PollListResponse> listMyPolls(
      {required String scope, int page = 1, int limit = 20}) async {
    lastMineScope = scope;
    if (mineCompleter != null) return mineCompleter!.future;
    return PollListResponse(
        items: [pollPost()], page: page, limit: limit, total: 1);
  }

  @override
  Future<void> deletePoll(int pollId) async {}
}

class RecordingPostProvider extends PostProvider {
  RecordingPostProvider() : super(Dio());

  Post? applied;
  int? removed;

  @override
  void applyExternalPostUpdate(Post updated) => applied = updated;

  @override
  void removeExternalPost(int postId) => removed = postId;
}

void main() {
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
}
