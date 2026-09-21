import 'dart:io';
import '../features/emoji/application/emoji_recent_manager.dart';
import '../features/emoji/adapters/builtin_sticker_adapter.dart';
import '../features/emoji/adapters/favorite_item_adapter.dart';
import '../features/emoji/domain/emoji_asset_ref.dart';

import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image_picker/image_picker.dart';

import '../config/api_constants.dart';
import '../controllers/post_reply_composer_controller.dart';
import '../models/reply.dart';
import 'async_action_guard.dart';
import 'idempotency_key.dart';
import 'post_reply_cache.dart';
import '../utils/public_image_compressor.dart';

class PostReplyService {
  PostReplyService(this._dio, {EmojiRecentManager? recentManager})
      : _recentManager = recentManager ?? EmojiRecentManager.instance;

  final EmojiRecentManager _recentManager;

  final Dio _dio;
  final AsyncActionGuard _actionGuard = AsyncActionGuard();
  final Map<String, String> _idempotencyKeys = <String, String>{};
  final Map<String, List<int>> _uploadedFileIds = <String, List<int>>{};
  final PublicImageCompressor _publicImageCompressor = PublicImageCompressor();

  Future<Reply> submit(
    int postId,
    PostReplyDraft draft, {
    String? idempotencyKey,
  }) {
    final actionKey = _replyActionKey(postId, draft);
    final recentAccount = _recentManager.userId;
    return _actionGuard.run<Reply>(actionKey, () async {
      final suppliedKey = idempotencyKey?.trim();
      final requestKey = suppliedKey == null || suppliedKey.isEmpty
          ? (_idempotencyKeys[actionKey] ??= newIdempotencyKey('reply'))
          : suppliedKey;
      final reply = await _submitOnce(
        postId,
        draft,
        actionKey: actionKey,
        idempotencyKey: requestKey,
      );
      _idempotencyKeys.remove(actionKey);
      _uploadedFileIds.remove(actionKey);
      await _recentManager.recordConfirmed([
        ...EmojiRecentManager.unicodeIn(draft.text),
        if (draft.emojiAsset != null) draft.emojiAsset!,
        if (draft.sticker != null)
          EmojiAssetRef(
              assetKey:
                  BuiltinStickerAdapter().adapt(draft.sticker!).key.serialized),
        if (draft.favoriteImage != null)
          EmojiAssetRef(
              assetKey: FavoriteItemAdapter()
                  .adapt(draft.favoriteImage!)
                  .key
                  .serialized),
      ], accountId: recentAccount);
      return reply;
    });
  }

  Future<Reply> _submitOnce(
    int postId,
    PostReplyDraft draft, {
    required String actionKey,
    required String idempotencyKey,
  }) async {
    final adapted = draft.sticker != null
        ? BuiltinStickerAdapter().adapt(draft.sticker!)
        : draft.favoriteImage != null
            ? FavoriteItemAdapter().adapt(draft.favoriteImage!)
            : null;
    final emojiAsset = draft.emojiAsset ??
        (adapted == null
            ? null
            : EmojiAssetRef(
                assetKey: adapted.key.serialized, packId: adapted.key.packId));
    final cachedFileIds = _uploadedFileIds[actionKey];
    final fileIds =
        cachedFileIds == null ? <int>[] : List<int>.from(cachedFileIds);
    if (cachedFileIds == null) {
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
      _uploadedFileIds[actionKey] = List<int>.from(fileIds);
    }
    final response = await _dio.post(
      '/posts/$postId/replies',
      data: FormData.fromMap({
        'content': draft.text.trim(),
        if (draft.sticker != null) 'sticker_id': draft.sticker!.id,
        if (emojiAsset case final asset?) ...{
          'asset_key': asset.assetKey,
          if (asset.packId != null) 'pack_id': asset.packId,
        },
        if (fileIds.isNotEmpty) 'file_ids': fileIds.join(','),
        if (draft.parentReplyId != null)
          'parent_reply_id': draft.parentReplyId.toString(),
        if (draft.replyToUserId != null)
          'reply_to_user_id': draft.replyToUserId.toString(),
        if (draft.replyToReplyId != null)
          'reply_to_reply_id': draft.replyToReplyId.toString(),
      }),
      options: _writeOptions(idempotencyKey),
    );
    PostReplyCache.forClient(_dio).invalidate();
    return Reply.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  String _replyActionKey(int postId, PostReplyDraft draft) {
    return 'reply:$postId:${draft.text}:${draft.parentReplyId}:'
        '${draft.replyToUserId}:${draft.replyToReplyId}:'
        '${draft.sticker?.id}:${draft.favoriteImage?.imageUrl}:'
        '${draft.localImage?.path}';
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
    return _uploadPublicImage(XFile(file.path, name: fileName));
  }

  Future<int> _uploadLocalImage(String path, String fileName) async {
    return _uploadPublicImage(XFile(path, name: fileName));
  }

  Future<int> _uploadPublicImage(XFile source) async {
    final prepared = await _publicImageCompressor.prepare(source);
    try {
      final uploadFile = prepared.file;
      final path = uploadFile.path;
      final hasUsablePath = path.isNotEmpty && await File(path).exists();
      final multipart = hasUsablePath
          ? await MultipartFile.fromFile(path, filename: uploadFile.name)
          : MultipartFile.fromBytes(
              await uploadFile.readAsBytes(),
              filename: uploadFile.name,
            );
      final response = await _dio.post(
        '/upload',
        data: FormData.fromMap({'file': multipart}),
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
    } finally {
      await prepared.dispose();
    }
  }

  Map<String, String> _authHeaders() {
    final authorization = _dio.options.headers['Authorization']?.toString();
    if (authorization == null || authorization.trim().isEmpty) {
      return const <String, String>{};
    }
    return <String, String>{'Authorization': authorization};
  }

  Options? _writeOptions(String? idempotencyKey) {
    final key = idempotencyKey?.trim();
    if (key == null || key.isEmpty) return null;
    return Options(headers: <String, dynamic>{'Idempotency-Key': key});
  }
}
