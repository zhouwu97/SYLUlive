import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../config/api_constants.dart';
import '../../providers/theme_provider.dart';
import '../../services/publish_session_scope.dart';
import 'theme_appearance_exporter.dart';
import 'theme_downloads.dart';
import 'theme_manifest.dart';
import 'theme_pack_codec.dart';
import 'theme_pack_store.dart';

class ThemeStoreDisabledException implements Exception {
  const ThemeStoreDisabledException([this.message = '主题商城暂未开放']);
  final String message;
  @override
  String toString() => message;
}

class ThemeStoreApiException implements Exception {
  const ThemeStoreApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.field,
  });

  final String code;
  final String message;
  final int? statusCode;
  final String? field;

  @override
  String toString() => message;
}

class ThemeCatalogAuthor {
  const ThemeCatalogAuthor({
    required this.id,
    required this.nickname,
    required this.avatarUrl,
  });

  final int id;
  final String nickname;
  final String avatarUrl;

  factory ThemeCatalogAuthor.fromJson(Map<String, dynamic> json) {
    return ThemeCatalogAuthor(
      id: (json['id'] as num?)?.toInt() ?? 0,
      nickname: (json['nickname'] as String?) ?? '用户',
      avatarUrl: (json['avatarUrl'] as String?) ?? '',
    );
  }
}

class ThemeCatalogItem {
  const ThemeCatalogItem({
    required this.familyId,
    required this.version,
    required this.name,
    required this.description,
    required this.license,
    required this.author,
    required this.tags,
    required this.source,
    required this.previewLight,
    required this.previewDark,
    required this.packageUrl,
    required this.packageSize,
    required this.packageSha256,
    required this.minAppVersion,
    required this.downloads,
    required this.updatedAt,
    this.manifest,
  });

  final String familyId;
  final int version;
  final String name;
  final String description;
  final String license;
  final ThemeCatalogAuthor author;
  final List<String> tags;
  final String source;
  final String previewLight;
  final String previewDark;
  final String packageUrl;
  final int packageSize;
  final String packageSha256;
  final String minAppVersion;
  final int downloads;
  final String updatedAt;
  final Map<String, dynamic>? manifest;

  bool get isOfficial => source == 'official';

  factory ThemeCatalogItem.fromJson(Map<String, dynamic> json) {
    final rawAuthor = json['author'];
    final rawTags = json['tags'];
    final rawManifest = json['manifest'];
    return ThemeCatalogItem(
      familyId: (json['familyId'] as String?) ?? '',
      version: (json['version'] as num?)?.toInt() ?? 1,
      name: (json['name'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      license: (json['license'] as String?) ?? 'CC-BY-4.0',
      author: rawAuthor is Map
          ? ThemeCatalogAuthor.fromJson(Map<String, dynamic>.from(rawAuthor))
          : const ThemeCatalogAuthor(id: 0, nickname: '用户', avatarUrl: ''),
      tags: rawTags is List
          ? [for (final t in rawTags) t.toString()]
          : const <String>[],
      source: (json['source'] as String?) ?? 'community',
      previewLight: (json['previewLight'] as String?) ?? '',
      previewDark: (json['previewDark'] as String?) ?? '',
      packageUrl: (json['packageUrl'] as String?) ?? '',
      packageSize: (json['packageSize'] as num?)?.toInt() ?? 0,
      packageSha256: (json['packageSha256'] as String?) ?? '',
      minAppVersion: (json['minAppVersion'] as String?) ?? '1.0.0',
      downloads: (json['downloads'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as String?) ?? '',
      manifest: rawManifest is Map
          ? Map<String, dynamic>.from(rawManifest)
          : null,
    );
  }
}

class ThemeCatalogPage {
  const ThemeCatalogPage({
    required this.items,
    this.nextCursor,
  });

  final List<ThemeCatalogItem> items;
  final String? nextCursor;
}

class ThemeSubmissionItem {
  const ThemeSubmissionItem({
    required this.id,
    required this.familyId,
    required this.version,
    required this.authorUserId,
    required this.name,
    required this.description,
    required this.tags,
    required this.license,
    required this.source,
    required this.status,
    required this.minAppVersion,
    required this.fontCopyright,
    required this.fontLicenseNote,
    required this.packageSha256,
    required this.packageSize,
    required this.packageUrl,
    required this.previewLight,
    required this.previewDark,
    required this.reviewReasonCode,
    required this.reviewNote,
    required this.reasonMessage,
    required this.createdAt,
    required this.updatedAt,
    this.author,
    this.manifest,
    this.currentApproved,
  });

  final String id;
  final String familyId;
  final int version;
  final int authorUserId;
  final String name;
  final String description;
  final List<String> tags;
  final String license;
  final String source;
  final String status;
  final String minAppVersion;
  final String fontCopyright;
  final String fontLicenseNote;
  final String packageSha256;
  final int packageSize;
  final String packageUrl;
  final String previewLight;
  final String previewDark;
  final String reviewReasonCode;
  final String reviewNote;
  final String reasonMessage;
  final String createdAt;
  final String updatedAt;
  final ThemeCatalogAuthor? author;
  final Map<String, dynamic>? manifest;
  final ThemeSubmissionItem? currentApproved;

  factory ThemeSubmissionItem.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    final rawAuthor = json['author'];
    final rawManifest = json['manifest'];
    final rawApproved = json['currentApproved'];
    return ThemeSubmissionItem(
      id: (json['id'] as String?) ?? '',
      familyId: (json['familyId'] as String?) ?? '',
      version: (json['version'] as num?)?.toInt() ?? 1,
      authorUserId: (json['authorUserId'] as num?)?.toInt() ?? 0,
      name: (json['name'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      tags: rawTags is List
          ? [for (final t in rawTags) t.toString()]
          : const <String>[],
      license: (json['license'] as String?) ?? 'CC-BY-4.0',
      source: (json['source'] as String?) ?? 'community',
      status: (json['status'] as String?) ?? 'pending',
      minAppVersion: (json['minAppVersion'] as String?) ?? '1.0.0',
      fontCopyright: (json['fontCopyright'] as String?) ?? '',
      fontLicenseNote: (json['fontLicenseNote'] as String?) ?? '',
      packageSha256: (json['packageSha256'] as String?) ?? '',
      packageSize: (json['packageSize'] as num?)?.toInt() ?? 0,
      packageUrl: (json['packageUrl'] as String?) ?? '',
      previewLight: (json['previewLight'] as String?) ?? '',
      previewDark: (json['previewDark'] as String?) ?? '',
      reviewReasonCode: (json['reviewReasonCode'] as String?) ?? '',
      reviewNote: (json['reviewNote'] as String?) ?? '',
      reasonMessage: (json['reasonMessage'] as String?) ?? '',
      createdAt: (json['createdAt'] as String?) ?? '',
      updatedAt: (json['updatedAt'] as String?) ?? '',
      author: rawAuthor is Map
          ? ThemeCatalogAuthor.fromJson(Map<String, dynamic>.from(rawAuthor))
          : null,
      manifest: rawManifest is Map
          ? Map<String, dynamic>.from(rawManifest)
          : null,
      currentApproved: rawApproved is Map
          ? ThemeSubmissionItem.fromJson(Map<String, dynamic>.from(rawApproved))
          : null,
    );
  }
}

abstract final class ThemeReviewReasons {
  static String licenseLabel(String license) =>
      const {
        'personal-use': '仅限个人使用',
        'CC0-1.0': '可自由使用（CC0）',
        'CC-BY-4.0': '使用时需署名（CC BY）',
        'CC-BY-NC-4.0': '需署名，仅限非商业使用（CC BY-NC）',
      }[license] ??
      license;

  static const List<(String, String)> options = [
    ('contrast', '部分页面的文字看不清，请提高文字与背景的对比度'),
    ('wallpaper_text', '壁纸含文字、水印、二维码或联系方式'),
    ('copyright', '素材授权不清，或使用了未授权的作品'),
    ('content', '内容不符合社区规范'),
    ('icon_semantics', '底栏图标无法辨认原含义，或两态没有区别'),
    ('quality', '画面模糊、拉伸、主体被遮挡等质量问题'),
    ('metadata', '名称、简介或标签与内容不符，或含广告'),
    ('impersonation', '冒充官方或他人'),
    ('duplicate', '与已上架的主题重复'),
  ];

  static const List<String> allowedTags = [
    '浅色',
    '深色',
    '明暗自适应',
    '简约',
    '清新',
    '可爱',
    '动漫',
    '风景',
    '校园',
    '节日',
    '纯色',
    '高对比',
    '复古',
    '科技',
  ];

  static int compareSemver(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    for (var i = 0; i < 3; i++) {
      final na = i < pa.length ? (int.tryParse(pa[i]) ?? 0) : 0;
      final nb = i < pb.length ? (int.tryParse(pb[i]) ?? 0) : 0;
      if (na < nb) return -1;
      if (na > nb) return 1;
    }
    return 0;
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 KB';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _EtagCacheEntry<T> {
  const _EtagCacheEntry(this.etag, this.value);
  final String etag;
  final T value;
}

class ThemeStoreRepository {
  ThemeStoreRepository(this.dio);

  final Dio dio;
  final Map<String, _EtagCacheEntry<Object>> _etagCache = {};

  /// 直接解析服务端返回的完整 URL 或以 `/api/...` 开头的路径，绝不自行拼接版本路径。
  String resolveUrl(String urlOrPath) {
    final trimmed = urlOrPath.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    final base = dio.options.baseUrl.isNotEmpty
        ? dio.options.baseUrl
        : ApiConstants.baseUrl;
    return ApiConstants.fullUrlForBase(trimmed, base);
  }

  Never _rethrowMapped(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final data = error.response?.data;
      if (data is Map) {
        final code = (data['code'] as String?) ?? '';
        final msg = (data['error'] ?? data['message'] ?? '请求失败').toString();
        final field = data['field'] as String?;
        if (code == 'theme_store_disabled' || status == 503 && code.isEmpty) {
          if (code == 'theme_store_disabled') {
            throw ThemeStoreDisabledException(msg);
          }
        }
        throw ThemeStoreApiException(
          code: code.isNotEmpty
              ? code
              : (status == 404 ? 'theme_not_found' : 'theme_failed'),
          message: msg,
          statusCode: status,
          field: field,
        );
      }
      if (status == 404) {
        throw const ThemeStoreApiException(
          code: 'theme_not_found',
          message: '主题不存在或已下架',
          statusCode: 404,
        );
      }
    }
    throw error;
  }

  Future<ThemeCatalogPage> listCatalog({
    String sort = 'latest',
    String? tag,
    String? query,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final params = <String, dynamic>{
      'sort': sort,
      if (tag != null && tag.trim().isNotEmpty) 'tag': tag.trim(),
      if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      if (cursor != null && cursor.trim().isNotEmpty) 'cursor': cursor.trim(),
    };
    final cacheKey =
        'catalog:$sort:${params['tag'] ?? ''}:${params['q'] ?? ''}:${params['cursor'] ?? ''}';
    final cached = _etagCache[cacheKey] as _EtagCacheEntry<ThemeCatalogPage>?;
    try {
      final response = await dio.get<dynamic>(
        '/themes',
        queryParameters: params,
        cancelToken: cancelToken,
        options: Options(
          headers: cached == null ? null : {'If-None-Match': cached.etag},
          validateStatus: (s) => s == 200 || s == 304,
        ),
      );
      if (response.statusCode == 304 && cached != null) {
        return cached.value;
      }
      final map = Map<String, dynamic>.from(response.data as Map);
      final rawItems = (map['items'] as List?) ?? const [];
      final page = ThemeCatalogPage(
        items: [
          for (final item in rawItems)
            ThemeCatalogItem.fromJson(Map<String, dynamic>.from(item as Map)),
        ],
        nextCursor: map['nextCursor'] as String?,
      );
      final etag = response.headers.value('etag');
      if (etag != null && etag.isNotEmpty) {
        _etagCache[cacheKey] = _EtagCacheEntry<ThemeCatalogPage>(etag, page);
      }
      return page;
    } catch (e) {
      _rethrowMapped(e);
    }
  }

  Future<Map<String, ThemeCatalogItem>> checkUpdates(
    Iterable<String> familyIds, {
    CancelToken? cancelToken,
  }) async {
    final unique = familyIds
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (unique.isEmpty) return const {};
    final out = <String, ThemeCatalogItem>{};
    for (var offset = 0; offset < unique.length; offset += 50) {
      final end = (offset + 50 < unique.length) ? offset + 50 : unique.length;
      final batch = unique.sublist(offset, end);
      final joined = batch.join(',');
      final cacheKey = 'updates:$joined';
      final cached =
          _etagCache[cacheKey] as _EtagCacheEntry<List<ThemeCatalogItem>>?;
      try {
        final response = await dio.get<dynamic>(
          '/themes',
          queryParameters: {'ids': joined},
          cancelToken: cancelToken,
          options: Options(
            headers: cached == null ? null : {'If-None-Match': cached.etag},
            validateStatus: (s) => s == 200 || s == 304,
          ),
        );
        List<ThemeCatalogItem> list;
        if (response.statusCode == 304 && cached != null) {
          list = cached.value;
        } else {
          final map = Map<String, dynamic>.from(response.data as Map);
          final rawItems = (map['items'] as List?) ?? const [];
          list = [
            for (final item in rawItems)
              ThemeCatalogItem.fromJson(Map<String, dynamic>.from(item as Map)),
          ];
          final etag = response.headers.value('etag');
          if (etag != null && etag.isNotEmpty) {
            _etagCache[cacheKey] =
                _EtagCacheEntry<List<ThemeCatalogItem>>(etag, list);
          }
        }
        for (final item in list) {
          out[item.familyId.toLowerCase()] = item;
        }
      } catch (e) {
        _rethrowMapped(e);
      }
    }
    return out;
  }

  Future<ThemeCatalogItem> getDetail(
    String familyId, {
    CancelToken? cancelToken,
  }) async {
    final cleanId = familyId.trim().toLowerCase();
    final cacheKey = 'detail:$cleanId';
    final cached = _etagCache[cacheKey] as _EtagCacheEntry<ThemeCatalogItem>?;
    try {
      final response = await dio.get<dynamic>(
        '/themes/$cleanId',
        cancelToken: cancelToken,
        options: Options(
          headers: cached == null ? null : {'If-None-Match': cached.etag},
          validateStatus: (s) => s == 200 || s == 304,
        ),
      );
      if (response.statusCode == 304 && cached != null) {
        return cached.value;
      }
      final item = ThemeCatalogItem.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
      final etag = response.headers.value('etag');
      if (etag != null && etag.isNotEmpty) {
        _etagCache[cacheKey] = _EtagCacheEntry<ThemeCatalogItem>(etag, item);
      }
      return item;
    } catch (e) {
      _rethrowMapped(e);
    }
  }

  Future<List<ThemeCatalogItem>> listUserThemes(
    int userId, {
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await dio.get<dynamic>(
        '/users/$userId/themes',
        cancelToken: cancelToken,
      );
      final map = Map<String, dynamic>.from(response.data as Map);
      final rawItems = (map['items'] as List?) ?? const [];
      return [
        for (final item in rawItems)
          ThemeCatalogItem.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } catch (e) {
      _rethrowMapped(e);
    }
  }

  Future<ThemeSubmissionItem> submit({
    required Uint8List packageBytes,
    required String idempotencyKey,
    required PublishSessionScope session,
    String fileName = 'theme.sltheme',
    String? familyId,
    String? source,
    String? name,
    String? description,
    List<String>? tags,
    String? license,
    bool rightsConfirmed = true,
    CancelToken? cancelToken,
  }) async {
    final formData = FormData.fromMap({
      'idempotencyKey': idempotencyKey,
      'rightsConfirmed': rightsConfirmed ? 'true' : 'false',
      if (familyId != null && familyId.trim().isNotEmpty)
        'familyId': familyId.trim(),
      if (source != null && source.trim().isNotEmpty) 'source': source.trim(),
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (license != null) 'license': license,
      if (tags != null) 'tags': jsonEncode(tags),
      'package': MultipartFile.fromBytes(
        packageBytes,
        filename: fileName,
      ),
    });
    try {
      final response = await dio.post<dynamic>(
        '/themes/submissions',
        data: formData,
        cancelToken: cancelToken,
        options: Options(
          sendTimeout: const Duration(minutes: 3),
          receiveTimeout: const Duration(minutes: 3),
          headers: {'Idempotency-Key': idempotencyKey},
          extra: session.requestExtra,
        ),
      );
      return ThemeSubmissionItem.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
    } catch (e) {
      _rethrowMapped(e);
    }
  }

  Future<List<ThemeSubmissionItem>> listMySubmissions({
    required PublishSessionScope session,
    String? status,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await dio.get<dynamic>(
        '/themes/submissions',
        queryParameters: {
          if (status != null && status.isNotEmpty) 'status': status,
        },
        cancelToken: cancelToken,
        options: Options(extra: session.requestExtra),
      );
      final map = Map<String, dynamic>.from(response.data as Map);
      final rawItems = (map['items'] as List?) ?? const [];
      return [
        for (final item in rawItems)
          ThemeSubmissionItem.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } catch (e) {
      _rethrowMapped(e);
    }
  }

  Future<void> withdrawSubmission(
    String id, {
    required PublishSessionScope session,
    CancelToken? cancelToken,
  }) async {
    try {
      await dio.post<dynamic>(
        '/themes/submissions/${id.trim()}/withdraw',
        cancelToken: cancelToken,
        options: Options(extra: session.requestExtra),
      );
    } catch (e) {
      _rethrowMapped(e);
    }
  }

  Future<List<ThemeSubmissionItem>> adminList({
    required PublishSessionScope session,
    String status = 'pending',
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await dio.get<dynamic>(
        '/admin/themes',
        queryParameters: {'status': status},
        cancelToken: cancelToken,
        options: Options(extra: session.requestExtra),
      );
      final map = Map<String, dynamic>.from(response.data as Map);
      final rawItems = (map['items'] as List?) ?? const [];
      return [
        for (final item in rawItems)
          ThemeSubmissionItem.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } catch (e) {
      _rethrowMapped(e);
    }
  }

  Future<ThemeSubmissionItem> adminReview(
    String id, {
    required bool approve,
    String reasonCode = '',
    String note = '',
    required PublishSessionScope session,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await dio.post<dynamic>(
        '/admin/themes/${id.trim()}/review',
        data: {
          'approve': approve,
          if (!approve) 'reasonCode': reasonCode,
          if (note.trim().isNotEmpty) 'note': note.trim(),
        },
        cancelToken: cancelToken,
        options: Options(extra: session.requestExtra),
      );
      return ThemeSubmissionItem.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
    } catch (e) {
      _rethrowMapped(e);
    }
  }

  Future<void> adminRemove(
    String familyId, {
    required String reasonCode,
    String note = '',
    required PublishSessionScope session,
    CancelToken? cancelToken,
  }) async {
    try {
      await dio.post<dynamic>(
        '/admin/themes/${familyId.trim()}/remove',
        data: {
          'reasonCode': reasonCode,
          if (note.trim().isNotEmpty) 'note': note.trim(),
        },
        cancelToken: cancelToken,
        options: Options(extra: session.requestExtra),
      );
    } catch (e) {
      _rethrowMapped(e);
    }
  }
}

enum ThemeDownloadStatus { downloading, installing, failed, completed }

class ThemeDownloadTask {
  ThemeDownloadTask({
    required this.familyId,
    required this.version,
    required this.totalBytes,
    this.status = ThemeDownloadStatus.downloading,
    this.receivedBytes = 0,
    this.error,
  });

  final String familyId;
  final int version;
  final int totalBytes;
  ThemeDownloadStatus status;
  int receivedBytes;
  String? error;

  double? get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

/// 复用断点续传模式下载目录给出的版本化 `packageUrl`，完成后核对一次 SHA-256。
class ThemePackDownloadManager extends ChangeNotifier {
  static final _shared = Expando<ThemePackDownloadManager>();
  static ThemePackDownloadManager shared(
    ThemePackStore store,
    ThemeStoreRepository repository,
  ) =>
      _shared[store] ??= ThemePackDownloadManager(
        store: store,
        repository: repository,
      );

  ThemePackDownloadManager({
    required this.store,
    required this.repository,
  });

  final ThemePackStore store;
  final ThemeStoreRepository repository;

  final Map<String, ThemeDownloadTask> tasks = {};
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, String> _partPaths = {};

  static String taskKey(String familyId, int version) =>
      '${familyId.toLowerCase()}@$version';

  ThemeDownloadTask? taskFor(String familyId, int version) =>
      tasks[taskKey(familyId, version)];

  ThemeDownloadTask? activeTaskForFamily(String familyId) {
    final prefix = '${familyId.toLowerCase()}@';
    for (final entry in tasks.entries) {
      if (entry.key.startsWith(prefix) &&
          (entry.value.status == ThemeDownloadStatus.downloading ||
              entry.value.status == ThemeDownloadStatus.installing)) {
        return entry.value;
      }
    }
    return null;
  }

  Future<File> _partFileFor(String familyId, int version) async {
    final root = await store.directory;
    final dir = Directory(p.join(root.path, 'downloads'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, '${familyId.toLowerCase()}-v$version.part'));
  }

  Future<void> cancel(String familyId, int version) async {
    final key = taskKey(familyId, version);
    final token = _cancelTokens.remove(key);
    token?.cancel('用户取消下载');
    tasks.remove(key);
    final savedPath = _partPaths.remove(key);
    final partFile = savedPath != null
        ? File(savedPath)
        : await _partFileFor(familyId, version);
    if (await partFile.exists()) {
      try {
        await partFile.delete();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<InstalledTheme> downloadAndInstall({
    required ThemeCatalogItem item,
    required ThemeProvider provider,
    required String appVersion,
  }) async {
    final key = taskKey(item.familyId, item.version);
    if (_cancelTokens.containsKey(key)) {
      throw const ThemePackError('theme_conflict', 'download', '正在下载中');
    }
    final existing = await provider.themePacks.findInstalledVersion(
      item.familyId,
      item.version,
    );
    if (existing != null) {
      return InstalledTheme(
        existing.manifest,
        existing.directory,
        existing.installedAt,
        source: item.source,
        familyId: item.familyId,
      );
    }

    final token = CancelToken();
    _cancelTokens[key] = token;
    final task = ThemeDownloadTask(
      familyId: item.familyId,
      version: item.version,
      totalBytes: item.packageSize,
    );
    tasks[key] = task;
    notifyListeners();

    final partFile = await _partFileFor(item.familyId, item.version);
    _partPaths[key] = partFile.path;

    try {
      final bytes = await _downloadWithResumeAndVerifySha256(
        packageUrl: item.packageUrl,
        expectedSize: item.packageSize,
        expectedSha256: item.packageSha256,
        partFile: partFile,
        token: token,
        onProgress: (received) {
          task.receivedBytes = received;
          notifyListeners();
        },
      );
      if (token.isCancelled) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: item.packageUrl),
          reason: 'cancelled',
        );
      }

      task.status = ThemeDownloadStatus.installing;
      notifyListeners();

      final prepared = await ThemePackCodec.decodeStorePackage(
        bytes,
        appVersion: appVersion,
      );
      final name = ThemeAppearanceExporter.sanitizeFileName(
          item.name, fallback: item.familyId);
      await ThemeDownloads.save('$name-v${item.version}.sltheme', bytes);
      final installed = await provider.installStoreTheme(
        prepared,
        source: item.source,
        familyId: item.familyId,
      );
      task.status = ThemeDownloadStatus.completed;
      if (await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      tasks.remove(key);
      return installed;
    } catch (e) {
      if (token.isCancelled ||
          (e is DioException && e.type == DioExceptionType.cancel)) {
        if (await partFile.exists()) {
          try {
            await partFile.delete();
          } catch (_) {}
        }
        tasks.remove(key);
        rethrow;
      }
      task.status = ThemeDownloadStatus.failed;
      task.error = e is ThemePackError ? e.message : '下载或校验失败，请重试';
      rethrow;
    } finally {
      _cancelTokens.remove(key);
      _partPaths.remove(key);
      notifyListeners();
    }
  }

  /// 管理员或作者下载私有待审包用于跨页面试用，同样走真实鉴权与单次 SHA-256 核对。
  Future<PreparedThemePack> downloadPrivatePack({
    required ThemeSubmissionItem submission,
    required String appVersion,
    required PublishSessionScope session,
    CancelToken? cancelToken,
  }) async {
    final root = await store.directory;
    final dir = await Directory(p.join(root.path, 'downloads')).create(
      recursive: true,
    );
    final partFile = File(p.join(dir.path, 'priv-${submission.id}.part'));
    final tok = cancelToken ?? CancelToken();
    try {
      final bytes = await _downloadWithResumeAndVerifySha256(
        packageUrl: submission.packageUrl,
        expectedSize: submission.packageSize,
        expectedSha256: submission.packageSha256,
        partFile: partFile,
        token: tok,
        extra: session.requestExtra,
      );
      return ThemePackCodec.decodeStorePackage(bytes, appVersion: appVersion);
    } finally {
      if (await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
    }
  }

  Future<Uint8List> _downloadWithResumeAndVerifySha256({
    required String packageUrl,
    required int expectedSize,
    required String expectedSha256,
    required File partFile,
    required CancelToken token,
    Map<String, dynamic>? extra,
    void Function(int receivedBytes)? onProgress,
  }) async {
    final resolvedUri = Uri.parse(repository.resolveUrl(packageUrl));
    var offset = await partFile.exists() ? await partFile.length() : 0;
    if (expectedSize > 0 && offset > expectedSize) {
      await partFile.delete();
      offset = 0;
    }

    if (expectedSize <= 0 || offset < expectedSize) {
      final response = await repository.dio.getUri<ResponseBody>(
        resolvedUri,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          receiveTimeout: const Duration(minutes: 3),
          extra: extra,
          headers: offset == 0
              ? null
              : {
                  'Range': 'bytes=$offset-',
                  if (expectedSha256.isNotEmpty)
                    'If-Range': '"$expectedSha256"',
                },
          validateStatus: (s) => s == 200 || s == 206,
        ),
      );
      if (response.statusCode == 206) {
        final range = response.headers.value('content-range');
        if (range == null || !range.startsWith('bytes $offset-')) {
          offset = 0;
        }
      } else {
        offset = 0;
      }

      onProgress?.call(offset);
      final sink = partFile.openWrite(
        mode: offset == 0 ? FileMode.write : FileMode.append,
      );
      var received = offset;
      try {
        await for (final chunk in response.data!.stream) {
          if (token.isCancelled) {
            throw DioException.requestCancelled(
              requestOptions: RequestOptions(path: resolvedUri.toString()),
              reason: 'cancelled',
            );
          }
          received += chunk.length;
          if (expectedSize > 0 && received > expectedSize) {
            throw const ThemePackError('theme_too_large', 'package');
          }
          sink.add(chunk);
          onProgress?.call(received);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    } else {
      onProgress?.call(offset);
    }

    final bytes = await partFile.readAsBytes();
    if (expectedSize > 0 && bytes.length != expectedSize) {
      if (await partFile.exists()) await partFile.delete();
      throw const ThemePackError(
        'theme_zip_invalid',
        'size',
        '下载文件长度不完整，已清理损坏副本',
      );
    }
    if (expectedSha256.isNotEmpty) {
      final actualSha = sha256.convert(bytes).toString().toLowerCase();
      if (actualSha != expectedSha256.toLowerCase()) {
        if (await partFile.exists()) await partFile.delete();
        throw const ThemePackError(
          'theme_zip_invalid',
          'sha256',
          '主题包完整性校验不一致，已删除损坏文件',
        );
      }
    }
    return bytes;
  }
}
