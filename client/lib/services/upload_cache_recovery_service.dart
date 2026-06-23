import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class UploadCacheRecoveryService {
  UploadCacheRecoveryService._();

  static final Set<String> _attempted = {};
  static final Set<String> _inFlight = {};

  static Future<bool> recover({
    required String imageUrl,
    required Dio dio,
    required BaseCacheManager cacheManager,
    List<BaseCacheManager> fallbackCacheManagers = const [],
  }) async {
    if (kIsWeb) return false;

    final uploadPath = _uploadPath(imageUrl);
    if (uploadPath == null) return false;
    if (!_attempted.add(uploadPath)) return false;
    if (!_inFlight.add(uploadPath)) return false;

    try {
      final fileInfo = await _findCachedFile(
        imageUrl,
        cacheManager,
        fallbackCacheManagers,
      );
      final file = fileInfo?.file;
      if (file == null || !await file.exists()) return false;
      if (await file.length() > 10 * 1024 * 1024) return false;

      final fileName = _fileName(uploadPath);
      if (fileName == null) return false;

      final recoverResponse = await _postRecoverUpload(
        dio: dio,
        filePath: file.path,
        fileName: fileName,
        uploadPath: uploadPath,
      );
      final recoveredPath = _responseUploadPath(recoverResponse);
      if (recoverResponse != null && recoveredPath == uploadPath) {
        debugPrint('Recovered cached upload at original path: $uploadPath');
        return true;
      }

      final response = await _postNormalUpload(
        dio: dio,
        filePath: file.path,
        fileName: fileName,
      );

      final restoredPath = _responseUploadPath(response);
      final ok = response.statusCode == 200 && restoredPath == uploadPath;
      if (ok) {
        debugPrint('Recovered cached upload: $uploadPath');
      } else {
        debugPrint(
          'Cached upload recovery wrote $restoredPath, expected $uploadPath',
        );
      }
      return ok;
    } catch (e) {
      debugPrint('Cached upload recovery failed for $uploadPath: $e');
      return false;
    } finally {
      _inFlight.remove(uploadPath);
    }
  }

  static Future<Response<dynamic>?> _postRecoverUpload({
    required Dio dio,
    required String filePath,
    required String fileName,
    required String uploadPath,
  }) async {
    try {
      return await dio.post(
        '/upload/recover',
        data: FormData.fromMap({
          'expected_path': uploadPath,
          'file': await MultipartFile.fromFile(
            filePath,
            filename: fileName,
          ),
        }),
        options: _uploadOptions(),
      );
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      if (statusCode == 404 || statusCode == 405) return null;
      debugPrint('Cached upload path recovery failed for $uploadPath: $e');
      return null;
    }
  }

  static Future<Response<dynamic>> _postNormalUpload({
    required Dio dio,
    required String filePath,
    required String fileName,
  }) async {
    return dio.post(
      '/upload',
      data: FormData.fromMap({
        'file': await MultipartFile.fromFile(
          filePath,
          filename: fileName,
        ),
      }),
      options: _uploadOptions(),
    );
  }

  static Options _uploadOptions() {
    return Options(
      sendTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    );
  }

  static String? _responseUploadPath(Response<dynamic>? response) {
    final restoredUrl = response?.data is Map ? response?.data['url'] : null;
    return _uploadPath(restoredUrl?.toString() ?? '');
  }

  static Future<FileInfo?> _findCachedFile(
    String imageUrl,
    BaseCacheManager primary,
    List<BaseCacheManager> fallbacks,
  ) async {
    final keys = _cacheKeys(imageUrl);
    for (final manager in [primary, ...fallbacks]) {
      for (final key in keys) {
        final info = await manager.getFileFromCache(key);
        final file = info?.file;
        if (file != null && await file.exists()) return info;
      }
    }
    return null;
  }

  static List<String> _cacheKeys(String imageUrl) {
    final keys = <String>[imageUrl];
    final uri = Uri.tryParse(imageUrl);
    if (uri == null) return keys;

    if (uri.hasQuery || uri.hasFragment) {
      final cleanedParams = Map<String, String>.from(uri.queryParameters)
        ..remove('_avatar_retry');
      keys.add(uri.replace(queryParameters: cleanedParams).toString());
      keys.add(uri.replace(query: null, fragment: null).toString());
    }

    return keys.toSet().toList(growable: false);
  }

  static String? _uploadPath(String imageUrl) {
    final uri = Uri.tryParse(imageUrl.trim());
    if (uri == null || !uri.path.startsWith('/uploads/')) return null;
    return uri.path;
  }

  static String? _fileName(String uploadPath) {
    final name = Uri.parse(uploadPath).pathSegments.last;
    final lower = name.toLowerCase();
    final supported = lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif');
    return supported ? name : null;
  }
}
