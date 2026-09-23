import 'dart:convert';

import 'idempotency_key.dart';
import 'publish_session_scope.dart';

import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';

import '../models/post.dart';
import '../utils/public_image_compressor.dart';

class PollApiException implements Exception {
  final String code;
  final String message;
  final int? statusCode;

  const PollApiException(this.code, this.message, {this.statusCode});

  /// 给用户看的文案。
  ///
  /// 幂等冲突的服务端文案只说明现象（"Idempotency-Key 已用于不同请求"），
  /// 用户看不出下一步能做什么。这类统一换成可执行的提示，其余透传原样。
  String get userMessage => idempotencyUserMessage(code, message);

  @override
  String toString() => message;
}

class PollListResponse {
  final List<Post> items;
  final int page;
  final int limit;

  /// 本次请求可翻页的候选总数；推荐排序下等于候选池条数，可能小于 matchedTotal。
  final int total;

  /// 满足筛选条件的全站匹配数，用于解释「有多少条没进推荐池」。
  final int? matchedTotal;

  /// 服务端给出的「本页之后还有数据」；旧服务端没有这个字段时为 null。
  final bool? hasMore;

  /// 续页位置。带上它翻页走 keyset，不再依赖 offset：
  /// 并发新增会让 offset 整体位移，同一条投票因此被跳过或重复。
  /// 旧服务端没有该字段时为 null，此时退回按 page 翻页。
  final String? nextCursor;

  /// 传入的游标已经不能续页，本响应其实是第一页，必须整体替换而不是接着拼。
  final bool? cursorStale;

  const PollListResponse({
    required this.items,
    required this.page,
    required this.limit,
    required this.total,
    this.matchedTotal,
    this.hasMore,
    this.nextCursor,
    this.cursorStale,
  });
}

class PollDraft {
  final String title;
  final String description;
  final String category;
  final String selectionMode;
  final int maxChoices;
  final String resultsVisibility;
  final bool allowChange;
  final DateTime endsAt;
  final List<String> options;
  final List<int> fileIds;

  const PollDraft({
    required this.title,
    required this.description,
    required this.category,
    required this.selectionMode,
    required this.maxChoices,
    required this.resultsVisibility,
    required this.allowChange,
    required this.endsAt,
    required this.options,
    this.fileIds = const [],
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'category': category,
        'selection_mode': selectionMode,
        'max_choices': maxChoices,
        'results_visibility': resultsVisibility,
        'allow_change': allowChange,
        'ends_at': endsAt.toUtc().toIso8601String(),
        'options': options,
        'file_ids': fileIds,
      };

  /// 完整请求体的稳定指纹，幂等键按它归并。
  ///
  /// 只用标题和截止时间是不够的：说明、选项、分类、图片变化同样是另一次提交，
  /// 拿旧键发新请求体只会换来 idempotency_key_reused，用户改了内容也提交不上去。
  String get fingerprint => jsonEncode(toJson());
}

class PollService {
  final Dio dio;
  final PublicImageCompressor _publicImageCompressor = PublicImageCompressor();

  PollService(this.dio);

  Future<PollListResponse> listPolls({
    String sort = 'recommend',
    String category = 'all',
    int page = 1,
    int limit = 20,
    String? cursor,
  }) async {
    return _list('/polls', {
      'sort': sort,
      'category': category,
      'page': page,
      'limit': limit,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    });
  }

  Future<PollListResponse> listMyPolls({
    required String scope,
    int page = 1,
    int limit = 20,
    String? cursor,
  }) async {
    return _list('/me/polls', {
      'scope': scope,
      'page': page,
      'limit': limit,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    });
  }

  Future<Post> getPoll(int pollId) => _post(() => dio.get('/polls/$pollId'));

  Future<Post> createPoll(PollDraft draft,
          {String? idempotencyKey, PublishSessionScope? session}) =>
      _post(
        () => dio.post(
          '/polls',
          data: draft.toJson(),
          options: _writeOptions(idempotencyKey, session: session),
        ),
      );

  Future<Post> updatePoll(int pollId, PollDraft draft,
          {String? idempotencyKey, PublishSessionScope? session}) =>
      _post(
        () => dio.put(
          '/polls/$pollId',
          data: draft.toJson(),
          options: _writeOptions(idempotencyKey, session: session),
        ),
      );

  Future<Post> putBallot(int pollId, List<int> optionIds,
          {String? idempotencyKey, PublishSessionScope? session}) =>
      _post(
        () => dio.put(
          '/polls/$pollId/ballot',
          data: {'option_ids': optionIds},
          options: _writeOptions(idempotencyKey, session: session),
        ),
      );

  Future<Post> closePoll(int pollId,
          {String? idempotencyKey, PublishSessionScope? session}) =>
      _post(
        () => dio.post(
          '/polls/$pollId/close',
          options: _writeOptions(idempotencyKey, session: session),
        ),
      );

  Future<void> deletePoll(int pollId,
      {String? idempotencyKey, PublishSessionScope? session}) async {
    try {
      await dio.delete(
        '/polls/$pollId',
        options: _writeOptions(idempotencyKey, session: session),
      );
    } on DioException catch (error) {
      throw _mapError(error);
    }
  }

  Future<List<int>> uploadImages(List<XFile> images,
      {PublishSessionScope? session}) async {
    final ids = <int>[];
    for (final source in images) {
      final prepared = await _publicImageCompressor.prepare(source);
      try {
        final bytes = await prepared.file.readAsBytes();
        final response = await dio.post(
          '/upload',
          data: FormData.fromMap({
            'file': MultipartFile.fromBytes(
              bytes,
              filename: prepared.file.name,
            ),
          }),
          options: _writeOptions(null, session: session),
        );
        final value = response.data is Map ? response.data['file_id'] : null;
        if (value is num) ids.add(value.toInt());
      } on DioException catch (error) {
        throw _mapError(error);
      } finally {
        await prepared.dispose();
      }
    }
    return ids;
  }

  Future<PollListResponse> _list(
      String path, Map<String, dynamic> params) async {
    try {
      final response = await dio.get(path, queryParameters: params);
      final data = response.data as Map<String, dynamic>;
      return PollListResponse(
        items: ((data['items'] as List?) ?? const [])
            .map((item) => Post.fromJson(item as Map<String, dynamic>))
            .toList(),
        page: (data['page'] as num?)?.toInt() ?? 1,
        limit: (data['limit'] as num?)?.toInt() ?? 20,
        total: (data['total'] as num?)?.toInt() ?? 0,
        matchedTotal: (data['matched_total'] as num?)?.toInt(),
        hasMore: data['has_more'] is bool ? data['has_more'] as bool : null,
        nextCursor: (data['next_cursor'] as String?)?.trim(),
        cursorStale: data['cursor_stale'] is bool ? data['cursor_stale'] as bool : null,
      );
    } on DioException catch (error) {
      throw _mapError(error);
    }
  }

  Future<Post> _post(Future<Response<dynamic>> Function() request) async {
    try {
      final response = await request();
      return Post.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (error) {
      throw _mapError(error);
    }
  }

  Options? _writeOptions(String? idempotencyKey,
      {PublishSessionScope? session}) {
    final key = idempotencyKey?.trim();
    if ((key == null || key.isEmpty) && session == null) return null;
    return Options(
      headers: <String, dynamic>{
        if (key != null && key.isNotEmpty) 'Idempotency-Key': key,
      },
      extra: <String, dynamic>{
        if (session != null) ...session.requestExtra,
      },
    );
  }

  PollApiException _mapError(DioException error) {
    final data = error.response?.data;
    final map = data is Map ? data : const <String, dynamic>{};
    final code = map['code']?.toString() ?? 'poll_network_error';
    return PollApiException(
      code,
      (map['message'] ?? map['error'])?.toString() ?? _fallbackMessage(code),
      statusCode: error.response?.statusCode,
    );
  }

  /// 服务端没给文案时的本地兜底，必须说清楚用户下一步能做什么。
  String _fallbackMessage(String code) {
    return switch (code) {
      'poll_network_error' => '网络连接失败，请稍后重试',
      _ => idempotencyUserMessage(code, '投票操作失败，请稍后重试'),
    };
  }
}
