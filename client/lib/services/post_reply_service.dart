import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../config/api_constants.dart';
import '../controllers/post_reply_composer_controller.dart';
import '../models/reply.dart';

class PostReplyService {
  PostReplyService(this._dio);

  final Dio _dio;

  Future<Reply> submit(int postId, PostReplyDraft draft) async {
    final fileIds = <int>[];
    if (draft.localImage != null) {
      fileIds.add(
        await _uploadLocalImage(
          draft.localImage!.path,
          draft.localImage!.name,
        ),
      );
    } else if (draft.favoriteImage != null) {
      fileIds.add(await _uploadFavoriteImage(draft.favoriteImage!.imageUrl));
    }
    final response = await _dio.post(
      '/posts/$postId/replies',
      data: FormData.fromMap({
        'content': draft.text.trim(),
        if (draft.sticker != null) 'sticker_id': draft.sticker!.id,
        if (fileIds.isNotEmpty) 'file_ids': fileIds.join(','),
        if (draft.parentReplyId != null)
          'parent_reply_id': draft.parentReplyId.toString(),
        if (draft.replyToUserId != null)
          'reply_to_user_id': draft.replyToUserId.toString(),
        if (draft.replyToReplyId != null)
          'reply_to_reply_id': draft.replyToReplyId.toString(),
      }),
    );
    return Reply.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  Future<int> _uploadFavoriteImage(String? rawImageUrl) async {
    final imageUrl = rawImageUrl?.trim();
    if (imageUrl == null || imageUrl.isEmpty) {
      throw StateError('收藏图片地址为空');
    }
    final file = await DefaultCacheManager().getSingleFile(
      ApiConstants.fullUrl(imageUrl),
      headers: _authHeaders(),
    );
    final segments = Uri.tryParse(imageUrl)?.pathSegments ?? const [];
    final fileName = segments.isEmpty || segments.last.trim().isEmpty
        ? 'favorite-image.jpg'
        : segments.last.trim();
    final response = await _dio.post(
      '/upload',
      data: FormData.fromMap({
        'file': await MultipartFile.fromFile(file.path, filename: fileName),
      }),
    );
    final rawFileId =
        response.data is Map ? (response.data as Map)['file_id'] : null;
    final fileId = rawFileId is num
        ? rawFileId.toInt()
        : int.tryParse(rawFileId?.toString() ?? '');
    if (fileId == null || fileId <= 0) {
      throw StateError('服务器未返回有效图片 ID');
    }
    return fileId;
  }

  Future<int> _uploadLocalImage(String path, String fileName) async {
    final response = await _dio.post(
      '/upload',
      data: FormData.fromMap({
        'file': await MultipartFile.fromFile(path, filename: fileName),
      }),
    );
    final rawFileId =
        response.data is Map ? (response.data as Map)['file_id'] : null;
    final fileId = rawFileId is num
        ? rawFileId.toInt()
        : int.tryParse(rawFileId?.toString() ?? '');
    if (fileId == null || fileId <= 0) {
      throw StateError('服务器未返回有效图片 ID');
    }
    return fileId;
  }

  Map<String, String> _authHeaders() {
    final authorization = _dio.options.headers['Authorization']?.toString();
    if (authorization == null || authorization.trim().isEmpty) {
      return const <String, String>{};
    }
    return <String, String>{'Authorization': authorization};
  }
}
