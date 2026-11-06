import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../../services/publish_session_scope.dart';
import '../domain/emoji_pack_installation.dart';
import '../domain/emoji_local_id.dart';
import '../domain/emoji_creation_draft.dart';
import '../domain/emoji_creator.dart';
import 'emoji_pack_local_store.dart';

String emojiSubmissionStatus(String status) => switch (status) {
      'pending' => '待审核',
      'published' => '已上架',
      'rejected' => '已驳回',
      'unpublished' => '已下架',
      'withdrawn' => '已撤回',
      'superseded' => '历史版本',
      _ => '状态未知',
    };

class EmojiSubmission {
  const EmojiSubmission(
      {required this.id,
      required this.name,
      required this.status,
      required this.userId,
      required this.assetCount,
      required this.totalSize,
      this.description = '',
      this.reviewReason = '',
      this.packId,
      this.version = 1,
      this.coverAssetId,
      this.iconAssetId,
      this.tags = const [],
      this.assets = const []});
  final String id, name, status, description, reviewReason;
  final int userId, assetCount, totalSize;
  final List<EmojiSubmissionAsset> assets;
  final String? packId, coverAssetId, iconAssetId;
  final int version;
  final List<String> tags;
  String get catalogId => packId?.isNotEmpty == true ? packId! : id;
  factory EmojiSubmission.fromJson(Map<String, dynamic> json) =>
      EmojiSubmission(
          id: json['id'] as String,
          name: json['name'] as String,
          status: json['status'] as String,
          userId: json['user_id'] as int,
          assetCount: json['asset_count'] as int,
          totalSize: json['total_size'] as int,
          description: json['description'] as String? ?? '',
          reviewReason: json['review_reason'] as String? ?? '',
          packId: json['pack_id'] as String?,
          version: json['version'] as int? ?? 1,
          coverAssetId: json['cover_asset_id'] as String?,
          iconAssetId: json['icon_asset_id'] as String?,
          tags: List<String>.from(json['tags'] as List? ?? []),
          assets: (json['assets'] as List? ?? [])
              .map((asset) => EmojiSubmissionAsset.fromJson(
                  Map<String, dynamic>.from(asset as Map)))
              .toList());
}

class EmojiSubmissionAsset {
  const EmojiSubmissionAsset(
      {required this.id, required this.name, required this.animated});
  final String id, name;
  final bool animated;
  factory EmojiSubmissionAsset.fromJson(Map<String, dynamic> json) =>
      EmojiSubmissionAsset(
          id: json['id'] as String,
          name: json['name'] as String,
          animated: json['animated'] == true);
}

class EmojiSubmissionPage {
  const EmojiSubmissionPage(this.items, this.total);
  final List<EmojiSubmission> items;
  final int total;
}

class EmojiSubmissionRepository {
  EmojiSubmissionRepository(this.dio);
  final Dio dio;
  // 同一表单的网络重试复用键；重新打开投稿代表一次新的分享意图。
  final String _submissionAttempt = newEmojiLocalId();
  String _base(bool admin) =>
      admin ? '/admin/emoji-packs' : '/emoji/submissions';
  Options _options(PublishSessionScope session) =>
      Options(extra: session.requestExtra, followRedirects: false);

  Future<EmojiCreator> creator(
      {required PublishSessionScope session,
      required CancelToken token}) async {
    final response = await dio.get('/emoji/creator',
        cancelToken: token, options: _options(session));
    return EmojiCreator.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  Future<EmojiCreator> applyCreator(String description, int version,
      {required PublishSessionScope session,
      required CancelToken token}) async {
    final response = await dio.post('/emoji/creator',
        data: {
          'description': description.trim(),
          'version': version,
          'rights_confirmed': true
        },
        cancelToken: token,
        options: _options(session));
    return EmojiCreator.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  Future<EmojiCreatorPage> creators(String status, int page,
      {required PublishSessionScope session,
      required CancelToken token}) async {
    final response = await dio.get('/admin/emoji-creators',
        queryParameters: {'status': status, 'page': page},
        cancelToken: token,
        options: _options(session));
    final data = Map<String, dynamic>.from(response.data as Map);
    return EmojiCreatorPage(
        (data['items'] as List)
            .map((item) =>
                EmojiCreator.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        data['total'] as int);
  }

  Future<void> reviewCreator(EmojiCreator creator, String action, String reason,
      {required PublishSessionScope session,
      required CancelToken token}) async {
    await dio.post('/admin/emoji-creators/${creator.userId}/review',
        data: {'action': action, 'reason': reason, 'version': creator.version},
        cancelToken: token,
        options: _options(session));
  }

  Future<EmojiSubmissionPage> list(
      {required PublishSessionScope session,
      required CancelToken token,
      bool admin = false,
      String? status,
      int page = 1}) async {
    final response = await dio.get(_base(admin),
        queryParameters: {
          'page': page,
          'limit': 20,
          if (status != null) 'status': status
        },
        cancelToken: token,
        options: _options(session));
    final data = Map<String, dynamic>.from(response.data as Map);
    return EmojiSubmissionPage(
        (data['items'] as List)
            .map((item) => EmojiSubmission.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(),
        data['total'] as int);
  }

  Future<EmojiSubmission> detail(String id,
      {required PublishSessionScope session,
      required CancelToken token,
      bool admin = false}) async {
    final response = await dio.get('${_base(admin)}/${Uri.encodeComponent(id)}',
        cancelToken: token, options: _options(session));
    return EmojiSubmission.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  String assetUrl(String id, String assetId,
          {bool admin = false, bool thumbnail = false}) =>
      '${dio.options.baseUrl}${_base(admin)}/${Uri.encodeComponent(id)}/assets/${Uri.encodeComponent(assetId)}${thumbnail ? '?variant=thumbnail' : ''}';

  Future<void> review(String id, String action, String reason,
      {required PublishSessionScope session,
      required CancelToken token}) async {
    await dio.post('${_base(true)}/${Uri.encodeComponent(id)}/review',
        data: {'action': action, 'reason': reason},
        cancelToken: token,
        options: _options(session));
  }

  Future<void> withdraw(String id,
      {required PublishSessionScope session,
      required CancelToken token}) async {
    await dio.delete('${_base(false)}/${Uri.encodeComponent(id)}',
        cancelToken: token, options: _options(session));
  }

  Future<EmojiSubmission> submit(
      {required EmojiPackInstallation pack,
      required EmojiPackLocalStore store,
      required String name,
      required String description,
      required PublishSessionScope session,
      required CancelToken token,
      EmojiCreationDraft? draft,
      void Function(int, int)? onProgress}) async {
    if (pack.manifest.assets.isEmpty ||
        pack.manifest.assets.length > 100 ||
        pack.totalSize > 49 * 1024 * 1024) {
      throw StateError('每次投稿最多 100 张、合计 49 MB；单张不能超过 10 MB。');
    }
    if (draft != null &&
        (draft.sourcePackId != pack.packId ||
            draft.sourceVersion != pack.version ||
            draft.sourceManifestHash != pack.manifestSha256)) {
      throw StateError('素材版本已变化，请重新选择并检查草稿');
    }
    final coverIndex = pack.manifest.assets
        .indexWhere((asset) => asset.id == draft?.coverAssetId);
    final iconIndex = pack.manifest.assets
        .indexWhere((asset) => asset.id == draft?.iconAssetId);
    final tags = draft?.tags ?? const <String>[];
    final names = <String>[], images = <MapEntry<String, MultipartFile>>[];
    final directory = store.versionDirectory(pack.packId, pack.version);
    for (final asset in pack.manifest.assets) {
      if (token.isCancelled) throw token.cancelError!;
      if (asset.fileSize > 10 * 1024 * 1024) {
        throw StateError('单张表情不能超过 10 MB。');
      }
      final file = File('${directory.path}/${asset.path}');
      if (!await file.exists() ||
          await file.length() != asset.fileSize ||
          (await sha256.bind(file.openRead()).first).toString() !=
              asset.sha256.toLowerCase()) {
        throw StateError('本机表情文件已损坏，请重新导入或下载后投稿。');
      }
      final label = (draft?.names[asset.id] ?? asset.name).trim();
      if (label.isEmpty || label.characters.length > 40) {
        throw StateError('请为每张表情填写 1–40 个字符的对应文字');
      }
      names.add(label);
      images.add(MapEntry(
          'images',
          await MultipartFile.fromFile(file.path,
              filename: 'image-${images.length + 1}')));
    }
    if (token.isCancelled) throw token.cancelError!;
    final key = sha256
        .convert(utf8.encode(jsonEncode([
          draft?.attemptId ?? _submissionAttempt,
          name.trim(),
          description.trim(),
          names,
          draft?.revisionOf,
          coverIndex,
          iconIndex,
          tags,
          pack.manifest.assets.map((asset) => asset.sha256).toList()
        ])))
        .toString();
    final form = FormData.fromMap({
      'name': name.trim(),
      'description': description.trim(),
      'rights_confirmed': 'true',
      'names': jsonEncode(names),
      'cover_index': coverIndex < 0 ? 0 : coverIndex,
      'icon_index': iconIndex < 0 ? 0 : iconIndex,
      'tags': jsonEncode(tags),
      if (draft?.revisionOf != null) 'pack_id': draft!.revisionOf,
    })
      ..files.addAll(images);
    final response = await dio.post('/emoji/submissions',
        data: form,
        cancelToken: token,
        onSendProgress: onProgress,
        options: Options(
            extra: session.requestExtra,
            headers: {'Idempotency-Key': key},
            followRedirects: false,
            sendTimeout: const Duration(minutes: 2)));
    return EmojiSubmission.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }
}

String emojiSubmissionError(Object error) {
  if (error is StateError) return error.message.toString();
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    if (error.response?.statusCode == 404) return '服务暂不可用或投稿已移除，请稍后重试。';
    if (error.response?.statusCode == 413) return '上传文件过大，请减少图片后重试。';
    if (error.response?.statusCode == 401) return '登录已过期，请重新登录。';
    if (error.response?.statusCode == 403) return '当前账号没有操作权限。';
  }
  return '操作未完成，请检查网络后重试。';
}
