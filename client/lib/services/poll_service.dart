import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';

import '../models/post.dart';
import '../utils/public_image_compressor.dart';

class PollApiException implements Exception {
  final String code;
  final String message;
  final int? statusCode;

  const PollApiException(this.code, this.message, {this.statusCode});

  @override
  String toString() => message;
}

class PollListResponse {
  final List<Post> items;
  final int page;
  final int limit;
  final int total;

  const PollListResponse({
    required this.items,
    required this.page,
    required this.limit,
    required this.total,
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
  }) async {
    return _list('/polls', {
      'sort': sort,
      'category': category,
      'page': page,
      'limit': limit,
    });
  }

  Future<PollListResponse> listMyPolls({
    required String scope,
    int page = 1,
    int limit = 20,
  }) async {
    return _list('/me/polls', {'scope': scope, 'page': page, 'limit': limit});
  }

  Future<Post> getPoll(int pollId) => _post(() => dio.get('/polls/$pollId'));

  Future<Post> createPoll(PollDraft draft, {String? idempotencyKey}) => _post(
        () => dio.post(
          '/polls',
          data: draft.toJson(),
          options: _writeOptions(idempotencyKey),
        ),
      );

  Future<Post> updatePoll(int pollId, PollDraft draft,
          {String? idempotencyKey}) =>
      _post(
        () => dio.put(
          '/polls/$pollId',
          data: draft.toJson(),
          options: _writeOptions(idempotencyKey),
        ),
      );

  Future<Post> putBallot(int pollId, List<int> optionIds,
          {String? idempotencyKey}) =>
      _post(
        () => dio.put(
          '/polls/$pollId/ballot',
          data: {'option_ids': optionIds},
          options: _writeOptions(idempotencyKey),
        ),
      );

  Future<Post> closePoll(int pollId, {String? idempotencyKey}) => _post(
        () => dio.post(
          '/polls/$pollId/close',
          options: _writeOptions(idempotencyKey),
        ),
      );

  Future<void> deletePoll(int pollId, {String? idempotencyKey}) async {
    try {
      await dio.delete(
        '/polls/$pollId',
        options: _writeOptions(idempotencyKey),
      );
    } on DioException catch (error) {
      throw _mapError(error);
    }
  }

  Future<List<int>> uploadImages(List<XFile> images) async {
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

  Options? _writeOptions(String? idempotencyKey) {
    final key = idempotencyKey?.trim();
    if (key == null || key.isEmpty) return null;
    return Options(headers: <String, dynamic>{'Idempotency-Key': key});
  }

  PollApiException _mapError(DioException error) {
    final data = error.response?.data;
    final map = data is Map ? data : const <String, dynamic>{};
    return PollApiException(
      map['code']?.toString() ?? 'poll_network_error',
      map['error']?.toString() ?? '网络连接失败，请稍后重试',
      statusCode: error.response?.statusCode,
    );
  }
}
