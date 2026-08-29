import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/exam_paper.dart';

class ExamPaperApiException implements Exception {
  final String message;
  final String code;
  final int? statusCode;

  const ExamPaperApiException({
    required this.message,
    required this.code,
    this.statusCode,
  });

  factory ExamPaperApiException.fromDio(DioException error) {
    final data = _errorMap(error.response?.data);
    if (data != null) {
      return ExamPaperApiException(
        // 服务端统一错误格式为 {code, message, request_id}，error 仅旧接口兜底。
        message: (data['message'] ?? data['error'])?.toString() ??
            '请求失败，请稍后重试',
        code: data['code']?.toString() ?? 'request_failed',
        statusCode: error.response?.statusCode,
      );
    }
    return ExamPaperApiException(
      message: error.message ?? '网络连接失败，请稍后重试',
      code: 'network_error',
      statusCode: error.response?.statusCode,
    );
  }

  static Map<dynamic, dynamic>? _errorMap(dynamic data) {
    if (data is Map) return data;
    try {
      final decoded = switch (data) {
        List<int>() => jsonDecode(utf8.decode(data)),
        String() => jsonDecode(data),
        _ => null,
      };
      return decoded is Map ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => message;
}

class ExamPaperDeleteResult {
  final String message;
  final bool expRevoked;

  const ExamPaperDeleteResult({
    required this.message,
    required this.expRevoked,
  });

  factory ExamPaperDeleteResult.fromJson(Map<String, dynamic> json) {
    return ExamPaperDeleteResult(
      message: json['message']?.toString() ?? '操作成功',
      expRevoked: json['exp_revoked'] == true,
    );
  }
}

class ExamPaperService {
  static const int maxFileSize = 20 * 1024 * 1024;
  static const String storageHost = '139.196.148.174';
  static const int _maxPendingCompletions = 16;
  static const Duration _pendingCompletionTTL = Duration(minutes: 15);

  final Dio _dio;
  final Dio _storageDio;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final int? _authSessionScope;
  final int Function()? _currentAuthSessionScope;
  final Map<String, Future<ExamPaper>> _inFlightUploads = {};
  final LinkedHashMap<String, _PendingExamPaperCompletion> _pendingCompletions =
      LinkedHashMap();

  ExamPaperService(
    this._dio, {
    Dio? storageDio,
    Future<Directory> Function()? temporaryDirectoryProvider,
    int? authSessionScope,
    int Function()? currentAuthSessionScope,
  })  : assert(
          (authSessionScope == null) == (currentAuthSessionScope == null),
          'authSessionScope 和 currentAuthSessionScope 必须同时提供',
        ),
        _storageDio = storageDio ?? Dio(),
        _temporaryDirectoryProvider =
            temporaryDirectoryProvider ?? getTemporaryDirectory,
        _authSessionScope = authSessionScope,
        _currentAuthSessionScope = currentAuthSessionScope;

  Future<ExamPaperPage> list({
    String keyword = '',
    String academicYear = '',
    String semester = '',
    String examType = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/exam-papers',
        queryParameters: {
          if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
          if (academicYear.isNotEmpty) 'academic_year': academicYear,
          if (semester.isNotEmpty) 'semester': semester,
          if (examType.isNotEmpty) 'exam_type': examType,
          'sort': sort,
          'page': page,
          'page_size': pageSize,
        },
      );
      return ExamPaperPage.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<ExamPaper> get(int id) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/exam-papers/$id');
      return ExamPaper.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<ExamPaperPage> mySubmissions({
    String status = '',
    int page = 1,
    int pageSize = 20,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/exam-papers/my-submissions',
        queryParameters: {
          if (status.isNotEmpty) 'status': status,
          'page': page,
          'page_size': pageSize,
        },
      );
      return ExamPaperPage.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<ExamPaper> upload({
    required PlatformFile file,
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
    required bool privacyConfirmed,
    ProgressCallback? onSendProgress,
  }) async {
    _ensureAuthSession();
    if (file.extension?.toLowerCase() != 'pdf') {
      throw const ExamPaperApiException(
        message: '请选择 PDF 文件',
        code: 'invalid_pdf',
      );
    }
    if (file.size > maxFileSize) {
      throw const ExamPaperApiException(
        message: 'PDF 不能超过 20 MiB',
        code: 'file_too_large',
      );
    }

    final preparedFile = await _prepareUploadFile(
      file: file,
      courseName: courseName,
      academicYear: academicYear,
      semester: semester,
      examType: examType,
      privacyConfirmed: privacyConfirmed,
    );
    final fingerprint = preparedFile.fingerprint;
    _ensureAuthSession();
    _prunePendingCompletions(DateTime.now());
    final inFlight = _inFlightUploads[fingerprint];
    if (inFlight != null) return inFlight;

    final operation = _performUpload(
      fingerprint: fingerprint,
      file: file,
      fileBytes: preparedFile.bytes,
      courseName: courseName,
      academicYear: academicYear,
      semester: semester,
      examType: examType,
      privacyConfirmed: privacyConfirmed,
      onSendProgress: onSendProgress,
    );
    _inFlightUploads[fingerprint] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlightUploads[fingerprint], operation)) {
        _inFlightUploads.remove(fingerprint);
      }
    }
  }

  Future<ExamPaper> _performUpload({
    required String fingerprint,
    required PlatformFile file,
    required Uint8List fileBytes,
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
    required bool privacyConfirmed,
    ProgressCallback? onSendProgress,
  }) async {
    _ensureAuthSession();
    final pending = _pendingCompletions[fingerprint];
    if (pending != null) {
      return _completePendingUpload(fingerprint, pending);
    }

    late final Response<dynamic> sessionResponse;
    try {
      _ensureAuthSession();
      sessionResponse = await _dio.post<dynamic>(
        '/exam-papers/upload-sessions',
        data: {
          'course_name': courseName.trim(),
          'academic_year': academicYear,
          'semester': semester,
          'exam_type': examType,
          'privacy_confirmed': privacyConfirmed,
          'file_size': fileBytes.length,
        },
      );
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
    _ensureAuthSession();
    final session = _parseUploadSession(sessionResponse.data);

    late final Response<dynamic> uploadResponse;
    try {
      _ensureAuthSession();
      uploadResponse = await _storageDio.post<dynamic>(
        session.uploadUri.toString(),
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(fileBytes, filename: file.name),
        }),
        options: Options(
          contentType: 'multipart/form-data',
          headers: {'Authorization': 'Bearer ${session.uploadToken}'},
          followRedirects: false,
        ),
        onSendProgress: onSendProgress,
      );
    } on DioException catch (error) {
      throw _storageExceptionFromDio(error);
    }
    _ensureAuthSession();
    final receipt = _parseUploadReceipt(uploadResponse.data);
    final completion = _PendingExamPaperCompletion(
      sessionID: session.id,
      receipt: receipt,
      cachedAt: DateTime.now(),
    );
    _cachePendingCompletion(fingerprint, completion);
    return _completePendingUpload(fingerprint, completion);
  }

  Future<ExamPaper> _completePendingUpload(
    String fingerprint,
    _PendingExamPaperCompletion completion,
  ) async {
    try {
      _ensureAuthSession();
      final response = await _dio.post<dynamic>(
        '/exam-papers/upload-sessions/${completion.sessionID}/complete',
        data: {'receipt': completion.receipt},
      );
      _ensureAuthSession();
      final paper = _parseCompletedPaper(response.data);
      if (identical(_pendingCompletions[fingerprint], completion)) {
        _pendingCompletions.remove(fingerprint);
      }
      return paper;
    } on DioException catch (error) {
      final mapped = (error.response?.statusCode ?? 0) < 400
          ? const ExamPaperApiException(
              message: '文件已上传，但完成投稿失败，请点击重试',
              code: 'upload_complete_failed',
            )
          : ExamPaperApiException.fromDio(error);
      if (_completionCannotBeRetried(mapped.code) &&
          identical(_pendingCompletions[fingerprint], completion)) {
        _pendingCompletions.remove(fingerprint);
      }
      throw mapped;
    }
  }

  Future<({String fingerprint, Uint8List bytes})> _prepareUploadFile({
    required PlatformFile file,
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
    required bool privacyConfirmed,
  }) async {
    late final List<Object> fileIdentity;
    late final Uint8List fileBytes;
    if (file.path != null && file.path!.isNotEmpty) {
      var normalizedPath = path.normalize(path.absolute(file.path!));
      if (Platform.isWindows) normalizedPath = normalizedPath.toLowerCase();
      try {
        final source = File(normalizedPath);
        final stat = await source.stat();
        if (stat.type != FileSystemEntityType.file) {
          throw const ExamPaperApiException(
            message: '无法读取所选 PDF 文件',
            code: 'invalid_pdf',
          );
        }
        fileBytes = await source.readAsBytes();
        final digest = sha256.convert(fileBytes);
        fileIdentity = ['path', normalizedPath, digest.toString()];
      } on FileSystemException {
        throw const ExamPaperApiException(
          message: '无法读取所选 PDF 文件',
          code: 'invalid_pdf',
        );
      }
    } else if (file.bytes != null) {
      fileBytes = Uint8List.fromList(file.bytes!);
      fileIdentity = ['bytes', sha256.convert(fileBytes).toString()];
    } else {
      throw const ExamPaperApiException(
        message: '无法读取所选 PDF 文件',
        code: 'invalid_pdf',
      );
    }
    if (fileBytes.length > maxFileSize) {
      throw const ExamPaperApiException(
        message: 'PDF 不能超过 20 MiB',
        code: 'file_too_large',
      );
    }
    final payload = jsonEncode([
      fileIdentity,
      file.name,
      fileBytes.length,
      courseName.trim(),
      academicYear,
      semester,
      examType,
      privacyConfirmed,
      _authSessionScope,
    ]);
    return (
      fingerprint: sha256.convert(utf8.encode(payload)).toString(),
      bytes: fileBytes,
    );
  }

  void _cachePendingCompletion(
    String fingerprint,
    _PendingExamPaperCompletion completion,
  ) {
    _prunePendingCompletions(completion.cachedAt);
    _pendingCompletions.remove(fingerprint);
    while (_pendingCompletions.length >= _maxPendingCompletions) {
      String? inactiveKey;
      for (final key in _pendingCompletions.keys) {
        if (!_inFlightUploads.containsKey(key)) {
          inactiveKey = key;
          break;
        }
      }
      if (inactiveKey == null) break;
      _pendingCompletions.remove(inactiveKey);
    }
    _pendingCompletions[fingerprint] = completion;
  }

  void _prunePendingCompletions(DateTime now) {
    _pendingCompletions.removeWhere(
      (fingerprint, completion) =>
          !_inFlightUploads.containsKey(fingerprint) &&
          now.difference(completion.cachedAt) > _pendingCompletionTTL,
    );
  }

  void _ensureAuthSession() {
    final expected = _authSessionScope;
    final current = _currentAuthSessionScope;
    if (expected != null && current != null && current() != expected) {
      throw const ExamPaperApiException(
        message: '登录状态已变化，请重新上传',
        code: 'auth_session_changed',
      );
    }
  }

  static bool _completionCannotBeRetried(String code) {
    return const {
      'upload_session_not_found',
      'upload_session_expired',
      'upload_receipt_invalid',
      'upload_session_invalid',
    }.contains(code);
  }

  static ExamPaperApiException _storageExceptionFromDio(DioException error) {
    // 文件服务的 error 字段是协议机器串，只允许映射已知值，禁止直接展示响应正文。
    final data = error.response?.data;
    final storageError = data is Map && data['error'] is String
        ? (data['error'] as String).trim()
        : '';
    final ({String code, String message})? mapped = switch (storageError) {
      'unauthorized' => (
          message: '上传凭证已失效，请重新上传',
          code: 'upload_session_expired',
        ),
      'upload_session_expired' => (
          message: '上传会话已过期，请重新上传',
          code: 'upload_session_expired',
        ),
      'upload_session_invalid' => (
          message: '上传会话已失效，请重新上传',
          code: 'upload_session_invalid',
        ),
      'upload_retry_exhausted' => (
          message: '该文件上传失败次数过多，请重新选择文件',
          code: 'upload_retry_exhausted',
        ),
      'upload_unclaimed_quota_exceeded' => (
          message: '未完成的上传过多，请稍后重试',
          code: 'upload_storage_quota_exceeded',
        ),
      'upload_session_in_progress' => (
          message: '该文件正在上传，请稍后重试',
          code: 'upload_session_in_progress',
        ),
      'file_size_mismatch' => (
          message: '文件大小发生变化，请重新选择 PDF',
          code: 'file_size_mismatch',
        ),
      'file too large' => (
          message: 'PDF 不能超过 20 MiB',
          code: 'file_too_large',
        ),
      'invalid pdf' || 'encrypted pdf' => (
          message: 'PDF 文件无效或已加密，请更换文件',
          code: 'invalid_pdf',
        ),
      'insufficient storage' => (
          message: '文件服务器空间不足，请稍后重试',
          code: 'insufficient_storage',
        ),
      'validation busy' || 'validation_busy' => (
          message: '文件校验繁忙，请稍后重试',
          code: 'validation_busy',
        ),
      'storage unavailable' => (
          message: '文件服务器暂不可用，请稍后重试',
          code: 'storage_unavailable',
        ),
      _ => null,
    };
    final responseStatusCode = error.response?.statusCode;
    if (mapped != null) {
      return ExamPaperApiException(
        message: mapped.message,
        code: mapped.code,
        statusCode: responseStatusCode,
      );
    }

    final statusCode = responseStatusCode ?? 0;
    if (statusCode < 300) {
      return ExamPaperApiException(
        message: '文件上传失败，请检查网络后重试',
        code: 'storage_upload_failed',
        statusCode: responseStatusCode,
      );
    }
    return ExamPaperApiException(
      message: '文件上传失败，请稍后重试',
      code: 'storage_upload_failed',
      statusCode: responseStatusCode,
    );
  }

  Future<ExamPaperDeleteResult> deleteSubmission(int id) async {
    try {
      final response = await _dio.delete<Map<String, dynamic>>(
        '/exam-papers/my-submissions/$id',
      );
      return ExamPaperDeleteResult.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<void> withdraw(int id) async {
    await deleteSubmission(id);
  }

  Future<File> downloadPreview(ExamPaper paper) {
    return _downloadToTemporaryFile(
      endpoint: '/exam-papers/${paper.id}/preview',
      title: paper.title,
      suffix: 'preview',
    );
  }

  Future<File> downloadForShare(ExamPaper paper) {
    return _downloadToTemporaryFile(
      endpoint: '/exam-papers/${paper.id}/download',
      title: paper.title,
      suffix: 'download',
    );
  }

  Future<ExamPaperPage> adminList({
    required String status,
    String keyword = '',
    String contributor = '',
    String sort = 'oldest',
    int page = 1,
    int pageSize = 20,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/admin/exam-papers',
        queryParameters: {
          'status': status,
          if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
          if (contributor.trim().isNotEmpty) 'contributor': contributor.trim(),
          'sort': sort,
          'page': page,
          'page_size': pageSize,
        },
      );
      return ExamPaperPage.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<List<ExamPaper>> adminListAll({
    required String status,
    String keyword = '',
    String contributor = '',
    String sort = 'oldest',
    int pageSize = 50,
  }) async {
    final items = <ExamPaper>[];
    var page = 1;
    while (true) {
      final result = await adminList(
        status: status,
        keyword: keyword,
        contributor: contributor,
        sort: sort,
        page: page,
        pageSize: pageSize,
      );
      items.addAll(result.items);
      if (!result.hasMore || result.page < page) break;
      page = result.page + 1;
    }
    return items;
  }

  Future<int> adminPendingCount() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/admin/exam-papers/pending-count',
      );
      return (response.data?['count'] as num?)?.toInt() ?? 0;
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<ExamPaper> adminGet(int id) async {
    try {
      final response =
          await _dio.get<Map<String, dynamic>>('/admin/exam-papers/$id');
      return ExamPaper.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<ExamPaper> approve({
    required int id,
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
    String reason = '',
  }) {
    return _adminMetadataRequest(
      method: 'POST',
      endpoint: '/admin/exam-papers/$id/approve',
      courseName: courseName,
      academicYear: academicYear,
      semester: semester,
      examType: examType,
      reason: reason,
    );
  }

  Future<void> reject({required int id, required String reason}) async {
    try {
      await _dio.post<void>(
        '/admin/exam-papers/$id/reject',
        data: {'reason': reason.trim()},
      );
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<ExamPaper> updatePublished({
    required int id,
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
  }) {
    return _adminMetadataRequest(
      method: 'PATCH',
      endpoint: '/admin/exam-papers/$id',
      courseName: courseName,
      academicYear: academicYear,
      semester: semester,
      examType: examType,
    );
  }

  Future<ExamPaper> unpublish({
    required int id,
    required String reason,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/admin/exam-papers/$id/unpublish',
        data: {'reason': reason.trim()},
      );
      return ExamPaper.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<ExamPaper> _adminMetadataRequest({
    required String method,
    required String endpoint,
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
    String reason = '',
  }) async {
    final data = {
      'course_name': courseName.trim(),
      'academic_year': academicYear,
      'semester': semester,
      'exam_type': examType,
      if (reason.trim().isNotEmpty) 'reason': reason.trim(),
    };
    try {
      final response = method == 'PATCH'
          ? await _dio.patch<Map<String, dynamic>>(endpoint, data: data)
          : await _dio.post<Map<String, dynamic>>(endpoint, data: data);
      return ExamPaper.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
  }

  Future<File> _downloadToTemporaryFile({
    required String endpoint,
    required String title,
    required String suffix,
  }) async {
    Uint8List bytes;
    try {
      final response = await _dio.get<List<int>>(
        endpoint,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) =>
              status == 200 ||
              status == 302 ||
              (status != null && status >= 400 && status < 600),
        ),
      );
      switch (response.statusCode) {
        case 200:
          bytes = _validatePdfBytes(response.data);
        case 302:
          final uri = _parseAndValidateDownloadRedirect(
            response.headers.value('location'),
          );
          bytes = await _downloadFromStorage(uri);
        default:
          throw ExamPaperApiException.fromDio(
            DioException(
              requestOptions: response.requestOptions,
              response: response,
              type: DioExceptionType.badResponse,
            ),
          );
      }
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }

    final directory = await _temporaryDirectoryProvider();
    final safeTitle = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final baseName =
        '${safeTitle}_${suffix}_${DateTime.now().microsecondsSinceEpoch}';
    final partFile = File(path.join(directory.path, '$baseName.part'));
    final finalFile = File(path.join(directory.path, '$baseName.pdf'));
    try {
      await partFile.writeAsBytes(bytes, flush: true);
      return await partFile.rename(finalFile.path);
    } catch (_) {
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<Uint8List> _downloadFromStorage(Uri uri) async {
    try {
      final response = await _storageDio.get<List<int>>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) => status == 200,
          headers: const {
            'Accept': 'application/pdf',
            'Authorization': null,
            'Cookie': null,
          },
        ),
      );
      return _validatePdfBytes(response.data);
    } on DioException catch (error) {
      throw ExamPaperApiException(
        message: '试卷文件下载失败，请稍后重试',
        code: 'storage_download_failed',
        statusCode: error.response?.statusCode,
      );
    }
  }

  static Uri _parseAndValidateDownloadRedirect(String? location) {
    final uri = location == null ? null : Uri.tryParse(location);
    final query = uri?.queryParametersAll;
    final pathSegments = uri?.pathSegments ?? const <String>[];
    final validPath = uri != null &&
        uri.path.startsWith('/v1/files/') &&
        uri.path.length > '/v1/files/'.length &&
        !pathSegments.any(
            (segment) => segment.isEmpty || segment == '.' || segment == '..');
    final validQuery = query != null &&
        query.length == 1 &&
        query.keys.single == 'token' &&
        query['token']!.length == 1 &&
        query['token']!.single.trim().isNotEmpty;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != storageHost ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !validPath ||
        !validQuery) {
      throw const ExamPaperApiException(
        message: '试卷文件地址无效，请稍后重试',
        code: 'invalid_storage_url',
      );
    }
    return uri;
  }

  static Uint8List _validatePdfBytes(List<int>? data) {
    if (data == null || data.isEmpty) {
      throw const ExamPaperApiException(
        message: '下载的 PDF 文件为空',
        code: 'invalid_pdf',
      );
    }
    if (data.length > maxFileSize) {
      throw const ExamPaperApiException(
        message: '下载的 PDF 不能超过 20 MiB',
        code: 'file_too_large',
      );
    }
    const signature = <int>[0x25, 0x50, 0x44, 0x46, 0x2d];
    final searchLength = data.length < 1024 ? data.length : 1024;
    var hasPdfHeader = false;
    for (var index = 0; index <= searchLength - signature.length; index++) {
      var matches = true;
      for (var offset = 0; offset < signature.length; offset++) {
        if (data[index + offset] != signature[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        hasPdfHeader = true;
        break;
      }
    }
    if (!hasPdfHeader) {
      throw const ExamPaperApiException(
        message: '下载内容不是有效的 PDF 文件',
        code: 'invalid_pdf',
      );
    }
    return Uint8List.fromList(data);
  }

  static Map<String, dynamic> _responseMap(Map<String, dynamic>? data) {
    return data ?? const <String, dynamic>{};
  }

  static _ExamPaperUploadSession _parseUploadSession(
    dynamic data,
  ) {
    final json = _requireResponseMap(data, 'invalid_upload_session_response');
    final id = _requireNonEmptyString(
      json,
      'session_id',
      'invalid_upload_session_response',
    );
    final uploadURL = _requireNonEmptyString(
      json,
      'upload_url',
      'invalid_upload_session_response',
    );
    final token = _requireNonEmptyString(
      json,
      'upload_token',
      'invalid_upload_session_response',
    );
    final expiresAt = _requireNonEmptyString(
      json,
      'expires_at',
      'invalid_upload_session_response',
    );
    if (DateTime.tryParse(expiresAt) == null) {
      throw const ExamPaperApiException(
        message: '上传会话响应无效，请稍后重试',
        code: 'invalid_upload_session_response',
      );
    }
    final uri = Uri.tryParse(uploadURL);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != storageHost ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.path != '/v1/uploads/${Uri.encodeComponent(id)}' ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ExamPaperApiException(
        message: '文件服务器地址无效，请稍后重试',
        code: 'invalid_storage_url',
      );
    }
    return _ExamPaperUploadSession(
      id: id,
      uploadUri: uri,
      uploadToken: token,
    );
  }

  static String _parseUploadReceipt(dynamic data) {
    final json = _requireResponseMap(data, 'invalid_storage_response');
    return _requireNonEmptyString(
      json,
      'receipt',
      'invalid_storage_response',
    );
  }

  static ExamPaper _parseCompletedPaper(dynamic data) {
    final json = _requireResponseMap(data, 'invalid_complete_response');
    _requirePositiveInt(json, 'id', 'invalid_complete_response');
    for (final field in [
      'status',
      'source',
      'course_name',
      'academic_year',
      'semester',
      'exam_type',
      'title',
      'created_at',
    ]) {
      _requireNonEmptyString(json, field, 'invalid_complete_response');
    }
    _requireNonNegativeInt(json, 'file_size', 'invalid_complete_response');
    _requireNonNegativeInt(
      json,
      'download_count',
      'invalid_complete_response',
    );
    if (json['reward_revocable'] is! bool) {
      throw const ExamPaperApiException(
        message: '投稿结果响应无效，请刷新后查看',
        code: 'invalid_complete_response',
      );
    }
    final contributor = json['contributor'];
    if (DateTime.tryParse(json['created_at'] as String) == null ||
        contributor is! Map<String, dynamic>) {
      throw const ExamPaperApiException(
        message: '投稿结果响应无效，请刷新后查看',
        code: 'invalid_complete_response',
      );
    }
    _requirePositiveInt(contributor, 'id', 'invalid_complete_response');
    _requireString(contributor, 'avatar', 'invalid_complete_response');
    _requireNonEmptyString(
      contributor,
      'nickname',
      'invalid_complete_response',
    );
    _requirePositiveInt(contributor, 'level', 'invalid_complete_response');
    return ExamPaper.fromJson(json);
  }

  static Map<String, dynamic> _requireResponseMap(
    dynamic data,
    String code,
  ) {
    if (data is! Map<String, dynamic>) {
      throw ExamPaperApiException(
        message: _invalidResponseMessage(code),
        code: code,
      );
    }
    return data;
  }

  static String _requireNonEmptyString(
    Map<String, dynamic> json,
    String field,
    String code,
  ) {
    final value = json[field];
    if (value is! String || value.trim().isEmpty) {
      throw ExamPaperApiException(
        message: _invalidResponseMessage(code),
        code: code,
      );
    }
    return value;
  }

  static String _requireString(
    Map<String, dynamic> json,
    String field,
    String code,
  ) {
    final value = json[field];
    if (value is! String) {
      throw ExamPaperApiException(
        message: _invalidResponseMessage(code),
        code: code,
      );
    }
    return value;
  }

  static int _requirePositiveInt(
    Map<String, dynamic> json,
    String field,
    String code,
  ) {
    final value = _requireInt(json, field, code);
    if (value <= 0) {
      throw ExamPaperApiException(
        message: _invalidResponseMessage(code),
        code: code,
      );
    }
    return value;
  }

  static int _requireNonNegativeInt(
    Map<String, dynamic> json,
    String field,
    String code,
  ) {
    final value = _requireInt(json, field, code);
    if (value < 0) {
      throw ExamPaperApiException(
        message: _invalidResponseMessage(code),
        code: code,
      );
    }
    return value;
  }

  static int _requireInt(
    Map<String, dynamic> json,
    String field,
    String code,
  ) {
    final value = json[field];
    if (value is! int) {
      throw ExamPaperApiException(
        message: _invalidResponseMessage(code),
        code: code,
      );
    }
    return value;
  }

  static String _invalidResponseMessage(String code) {
    return switch (code) {
      'invalid_upload_session_response' => '上传会话响应无效，请稍后重试',
      'invalid_storage_response' => '文件服务器响应无效，请稍后重试',
      _ => '投稿结果响应无效，请刷新后查看',
    };
  }
}

class _ExamPaperUploadSession {
  final String id;
  final Uri uploadUri;
  final String uploadToken;

  const _ExamPaperUploadSession({
    required this.id,
    required this.uploadUri,
    required this.uploadToken,
  });
}

class _PendingExamPaperCompletion {
  final String sessionID;
  final String receipt;
  final DateTime cachedAt;

  const _PendingExamPaperCompletion({
    required this.sessionID,
    required this.receipt,
    required this.cachedAt,
  });
}
