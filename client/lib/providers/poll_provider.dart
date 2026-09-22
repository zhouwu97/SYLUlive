import 'package:flutter/foundation.dart';

import '../models/post.dart';
import '../services/poll_service.dart';
import '../services/idempotency_key.dart';
import '../services/publish_session_scope.dart';
import 'post_provider.dart';

class PollListState {
  List<Post> items = [];
  bool isLoading = false;
  bool isLoadingMore = false;
  String? error;
  int page = 0;
  bool hasMore = true;
  DateTime? lastRefreshAt;
  bool hasLoaded = false;
}

class PollProvider extends ChangeNotifier {
  final PollService service;
  PostProvider? _postProvider;
  final Map<String, PollListState> _states = {};
  final Set<int> _mutatingPollIds = {};
  final Map<int, String> _mutationErrors = {};
  int? _sessionUserId;
  int _sessionEpoch = 0;
  int _sessionGeneration = 0;
  String? lastActionError;
  final Map<String, String> _idempotencyKeys = <String, String>{};

  PollProvider(this.service, [this._postProvider]);

  void bindPostProvider(PostProvider provider) => _postProvider = provider;

  /// 切换账号时清除所有带有个性化字段的投票状态。
  ///
  /// 投票列表中的 hasVoted/isOwner/canChange 等字段都依赖当前查看者，
  /// 因此不能只清理“我的投票”两个列表。
  void syncSessionUser(int? userId, [int sessionEpoch = 0]) {
    if (_sessionUserId == userId && _sessionEpoch == sessionEpoch) return;
    _sessionUserId = userId;
    _sessionEpoch = sessionEpoch;
    _sessionGeneration++;
    _states.clear();
    _mutatingPollIds.clear();
    _mutationErrors.clear();
    _idempotencyKeys.clear();
    lastActionError = null;
    notifyListeners();
  }

  PublishSessionScope? get sessionScope => _sessionUserId == null
      ? null
      : PublishSessionScope(
          accountId: _sessionUserId!,
          accountSessionEpoch: _sessionEpoch,
        );

  bool ownsSession(PublishSessionScope scope) => scope.owns(
        userId: _sessionUserId,
        sessionEpoch: _sessionEpoch,
      );

  PollListState stateFor(
          {String sort = 'recommend', String category = 'all'}) =>
      _states.putIfAbsent('$sort|$category', PollListState.new);

  PollListState mineState(String scope) =>
      _states.putIfAbsent('mine|$scope', PollListState.new);

  bool isMutating(int pollId) => _mutatingPollIds.contains(pollId);
  String? mutationError(int pollId) => _mutationErrors[pollId];

  Future<void> load({
    String sort = 'recommend',
    String category = 'all',
    bool refresh = false,
  }) async {
    final key = '$sort|$category';
    final state = _states.putIfAbsent(key, PollListState.new);
    await _loadState(
      state,
      refresh: refresh,
      request: (page) => service.listPolls(
        sort: sort,
        category: category,
        page: page,
      ),
    );
  }

  Future<void> loadMine(String scope, {bool refresh = false}) async {
    final state = mineState(scope);
    await _loadState(
      state,
      refresh: refresh,
      request: (page) => service.listMyPolls(scope: scope, page: page),
    );
  }

  Future<void> _loadState(
    PollListState state, {
    required bool refresh,
    required Future<PollListResponse> Function(int page) request,
  }) async {
    if (state.isLoading || state.isLoadingMore) return;
    if (!refresh && state.hasLoaded && !state.hasMore) return;
    final requestGeneration = _sessionGeneration;
    final requestUserId = _sessionUserId;
    final nextPage = refresh || !state.hasLoaded ? 1 : state.page + 1;
    if (nextPage == 1) {
      state.isLoading = true;
    } else {
      state.isLoadingMore = true;
    }
    state.error = null;
    notifyListeners();
    try {
      final response = await request(nextPage);
      if (!_isCurrentSession(requestGeneration, requestUserId)) return;
      if (nextPage == 1) {
        state.items = response.items;
      } else {
        final known = state.items.map((item) => item.id).toSet();
        state.items.addAll(response.items.where((item) => known.add(item.id)));
      }
      state.page = response.page;
      // 优先用服务端结论：total 只表示可翻页候选数，本页变短（并发写入、筛选）
      // 时按 total 反推会误判。旧服务端没有 has_more 才退回按长度猜。
      state.hasMore = response.hasMore ??
          (state.items.length < response.total &&
              response.items.length >= response.limit);
      state.hasLoaded = true;
      state.lastRefreshAt = DateTime.now();
    } on PollApiException catch (error) {
      if (!_isCurrentSession(requestGeneration, requestUserId)) return;
      state.error = error.userMessage;
    } catch (_) {
      if (!_isCurrentSession(requestGeneration, requestUserId)) return;
      state.error = '加载投票失败，请稍后重试';
    } finally {
      if (_isCurrentSession(requestGeneration, requestUserId)) {
        state.isLoading = false;
        state.isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<Post?> submitBallot(int pollId, List<int> optionIds) async {
    if (_mutatingPollIds.contains(pollId)) return null;
    final actionKey = 'poll-ballot:$pollId:${optionIds.join(',')}';
    final session = sessionScope;
    return _mutate(
      pollId,
      actionKey,
      (idempotencyKey) => service.putBallot(
        pollId,
        optionIds,
        idempotencyKey: idempotencyKey,
        session: session,
      ),
    );
  }

  Future<Post?> closePoll(int pollId) async {
    if (_mutatingPollIds.contains(pollId)) return null;
    final actionKey = 'poll-close:$pollId';
    final session = sessionScope;
    return _mutate(
      pollId,
      actionKey,
      (idempotencyKey) => service.closePoll(
        pollId,
        idempotencyKey: idempotencyKey,
        session: session,
      ),
    );
  }

  Future<Post?> updatePoll(int pollId, PollDraft draft,
      {PublishSessionScope? session}) async {
    if (_mutatingPollIds.contains(pollId)) return null;
    final actionKey = 'poll-update:$pollId:${draft.fingerprint}';
    final requestSession = session ?? sessionScope;
    return _mutate(
      pollId,
      actionKey,
      (idempotencyKey) => service.updatePoll(
        pollId,
        draft,
        idempotencyKey: idempotencyKey,
        session: requestSession,
      ),
    );
  }

  /// 创建投票的稳定操作标识：同一份草稿重试归并到同一次操作。
  String actionKeyForCreate(PollDraft draft) =>
      'poll-create:${draft.fingerprint}';

  Future<Post?> createPoll(PollDraft draft,
      {PublishSessionScope? session}) async {
    final requestGeneration = _sessionGeneration;
    final requestUserId = _sessionUserId;
    final requestSession = session ?? sessionScope;
    lastActionError = null;
    // 幂等键必须绑定完整请求体：说明、选项、分类、图片变化同样是另一次提交。
    final actionKey = actionKeyForCreate(draft);
    try {
      final post = await service.createPoll(
        draft,
        idempotencyKey: _idempotencyKeyFor(actionKey),
        session: requestSession,
      );
      if (!_isCurrentSession(requestGeneration, requestUserId)) return null;
      _idempotencyKeys.remove(actionKey);
      _upsertIntoLoadedState('latest|all', post, insert: true);
      _postProvider?.applyExternalPostUpdate(post);
      notifyListeners();
      return post;
    } on PollApiException catch (error) {
      if (!_isCurrentSession(requestGeneration, requestUserId)) return null;
      _releaseIdempotencyKey(actionKeyForCreate(draft), error);
      lastActionError = error.userMessage;
      return null;
    }
  }

  Future<bool> deletePoll(int pollId) async {
    if (_mutatingPollIds.contains(pollId)) return false;
    final requestGeneration = _sessionGeneration;
    final requestUserId = _sessionUserId;
    _mutatingPollIds.add(pollId);
    _mutationErrors.remove(pollId);
    notifyListeners();
    final actionKey = 'poll-delete:$pollId';
    final session = sessionScope;
    try {
      await service.deletePoll(
        pollId,
        idempotencyKey: _idempotencyKeyFor(actionKey),
        session: session,
      );
      if (!_isCurrentSession(requestGeneration, requestUserId)) return false;
      _idempotencyKeys.remove(actionKey);
      int? postId;
      for (final state in _states.values) {
        for (final post in state.items) {
          if (post.pollMeta?.id == pollId) postId = post.id;
        }
        state.items.removeWhere((post) => post.pollMeta?.id == pollId);
      }
      if (postId != null) _postProvider?.removeExternalPost(postId);
      return true;
    } on PollApiException catch (error) {
      if (!_isCurrentSession(requestGeneration, requestUserId)) return false;
      _releaseIdempotencyKey(actionKey, error);
      _mutationErrors[pollId] = error.userMessage;
      return false;
    } finally {
      if (_isCurrentSession(requestGeneration, requestUserId)) {
        _mutatingPollIds.remove(pollId);
        notifyListeners();
      }
    }
  }

  Future<Post?> _mutate(
    int pollId,
    String actionKey,
    Future<Post> Function(String idempotencyKey) request,
  ) async {
    final requestGeneration = _sessionGeneration;
    final requestUserId = _sessionUserId;
    _mutatingPollIds.add(pollId);
    _mutationErrors.remove(pollId);
    notifyListeners();
    try {
      final post = await request(_idempotencyKeyFor(actionKey));
      if (!_isCurrentSession(requestGeneration, requestUserId)) return null;
      _idempotencyKeys.remove(actionKey);
      _replaceEverywhere(post);
      _postProvider?.applyExternalPostUpdate(post);
      return post;
    } on PollApiException catch (error) {
      if (!_isCurrentSession(requestGeneration, requestUserId)) return null;
      _releaseIdempotencyKey(actionKey, error);
      _mutationErrors[pollId] = error.userMessage;
      return null;
    } finally {
      if (_isCurrentSession(requestGeneration, requestUserId)) {
        _mutatingPollIds.remove(pollId);
        notifyListeners();
      }
    }
  }

  bool _isCurrentSession(int generation, int? userId) {
    return generation == _sessionGeneration && userId == _sessionUserId;
  }

  void applyExternalPostUpdate(Post post) {
    _replaceEverywhere(post);
    notifyListeners();
  }

  void _replaceEverywhere(Post post) {
    for (final state in _states.values) {
      final index = state.items.indexWhere((item) => item.id == post.id);
      if (index >= 0) state.items[index] = post;
    }
  }

  void _upsertIntoLoadedState(String key, Post post, {bool insert = false}) {
    final state = _states[key];
    if (state == null || !state.hasLoaded) return;
    final index = state.items.indexWhere((item) => item.id == post.id);
    if (index >= 0) {
      state.items[index] = post;
    } else if (insert) {
      state.items.insert(0, post);
    }
  }

  String _idempotencyKeyFor(String actionKey) => _idempotencyKeys.putIfAbsent(
        actionKey,
        () => newIdempotencyKey('poll'),
      );

  /// 按错误结果决定幂等键的去留。
  ///
  /// 成功后丢键：这次操作已经落地，同样的内容再来一次是新的用户意图。
  /// 明确失败但结果已知（业务校验、限流）时**保留**键：服务端不缓存失败响应，
  /// 同一键可以原样重试；结果未知或键已被占用时丢键，让下一次点击成为新的一次操作。
  /// 盲目"每次重试都换新键"只是把幂等冲突换成重复创建。
  void _releaseIdempotencyKey(String actionKey, PollApiException error) {
    if (idempotencyOutcomeFor(error.code) == IdempotencyOutcome.exhausted) {
      _idempotencyKeys.remove(actionKey);
    }
  }
}
