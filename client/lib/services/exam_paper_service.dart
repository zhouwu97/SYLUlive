import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
        message: data['error']?.toString() ?? '请求失败，请稍后重试',
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
  static const String storageHost = 'sylulive.online';

  final Dio _dio;
  final Dio _storageDio;
  _PendingExamPaperCompletion? _pendingCompletion;

  ExamPaperService(this._dio, {Dio? storageDio})
      : _storageDio = storageDio ?? Dio();

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

    final pending = _pendingCompletion;
    if (pending != null &&
        pending.matches(
          file: file,
          courseName: courseName,
          academicYear: academicYear,
          semester: semester,
          examType: examType,
          privacyConfirmed: privacyConfirmed,
        )) {
      return _completePendingUpload(pending);
    }

    late final Response<dynamic> sessionResponse;
    try {
      sessionResponse = await _dio.post<dynamic>(
        '/exam-papers/upload-sessions',
        data: {
          'course_name': courseName.trim(),
          'academic_year': academicYear,
          'semester': semester,
          'exam_type': examType,
          'privacy_confirmed': privacyConfirmed,
          'file_size': file.size,
        },
      );
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
    final session = _parseUploadSession(sessionResponse.data);

    late final Response<dynamic> uploadResponse;
    try {
      uploadResponse = await _storageDio.post<dynamic>(
        session.uploadUri.toString(),
        data: FormData.fromMap({'file': await _multipartFile(file)}),
        options: Options(
          contentType: 'multipart/form-data',
          headers: {'Authorization': 'Bearer ${session.uploadToken}'},
          followRedirects: false,
        ),
        onSendProgress: onSendProgress,
      );
    } on DioException catch (error) {
      if ((error.response?.statusCode ?? 0) >= 400) {
        throw ExamPaperApiException.fromDio(error);
      }
      throw const ExamPaperApiException(
        message: '文件上传失败，请检查网络后重试',
        code: 'storage_upload_failed',
      );
    }
    final receipt = _parseUploadReceipt(uploadResponse.data);
    final completion = _PendingExamPaperCompletion(
      file: file,
      courseName: courseName.trim(),
      academicYear: academicYear,
      semester: semester,
      examType: examType,
      privacyConfirmed: privacyConfirmed,
      sessionID: session.id,
      receipt: receipt,
    );
    _pendingCompletion = completion;
    return _completePendingUpload(completion);
  }

  Future<ExamPaper> _completePendingUpload(
    _PendingExamPaperCompletion completion,
  ) async {
    try {
      final response = await _dio.post<dynamic>(
        '/exam-papers/upload-sessions/${completion.sessionID}/complete',
        data: {'receipt': completion.receipt},
      );
      final paper = _parseCompletedPaper(response.data);
      if (identical(_pendingCompletion, completion)) {
        _pendingCompletion = null;
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
          identical(_pendingCompletion, completion)) {
        _pendingCompletion = null;
      }
      throw mapped;
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

  Future<MultipartFile> _multipartFile(PlatformFile file) async {
    if (file.path != null && file.path!.isNotEmpty) {
      return MultipartFile.fromFile(file.path!, filename: file.name);
    }
    if (file.bytes != null) {
      return MultipartFile.fromBytes(file.bytes!, filename: file.name);
    }
    throw const ExamPaperApiException(
      message: '无法读取所选 PDF 文件',
      code: 'invalid_pdf',
    );
  }

  Future<File> _downloadToTemporaryFile({
    required String endpoint,
    required String title,
    required String suffix,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        endpoint,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = Uint8List.fromList(response.data ?? const <int>[]);
      if (bytes.isEmpty) {
        throw const ExamPaperApiException(
          message: '下载的 PDF 文件为空',
          code: 'invalid_pdf',
        );
      }
      final directory = await getTemporaryDirectory();
      final safeTitle = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File(
        path.join(
          directory.path,
          '${safeTitle}_${suffix}_${DateTime.now().microsecondsSinceEpoch}.pdf',
        ),
      );
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } on DioException catch (error) {
      throw ExamPaperApiException.fromDio(error);
    }
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
  final PlatformFile file;
  final String courseName;
  final String academicYear;
  final String semester;
  final String examType;
  final bool privacyConfirmed;
  final String sessionID;
  final String receipt;

  const _PendingExamPaperCompletion({
    required this.file,
    required this.courseName,
    required this.academicYear,
    required this.semester,
    required this.examType,
    required this.privacyConfirmed,
    required this.sessionID,
    required this.receipt,
  });

  bool matches({
    required PlatformFile file,
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
    required bool privacyConfirmed,
  }) {
    return identical(this.file, file) &&
        this.courseName == courseName.trim() &&
        this.academicYear == academicYear &&
        this.semester == semester &&
        this.examType == examType &&
        this.privacyConfirmed == privacyConfirmed;
  }
}
