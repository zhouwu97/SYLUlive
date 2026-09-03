import 'package:dio/dio.dart';

import '../models/course_evaluation.dart';

/// 课程评价 Dio 服务。
///
/// 只发送用户主动确认的课程名、教师名、星级、评论与候选 ID；
/// 绝不发送教室、周次、节次等课表私有字段。
class CourseEvaluationService {
  final Dio _dio;

  CourseEvaluationService(this._dio);

  Future<List<CourseSubject>> listSubjects() async {
    try {
      final res = await _dio.get('/course-subjects');
      final data = res.data;
      if (data is! List) return const [];
      return data
          .whereType<Map<String, dynamic>>()
          .map(CourseSubject.fromJson)
          .toList();
    } catch (e) {
      throw toCourseEvaluationException(e);
    }
  }

  Future<CourseSubjectDetail> getSubject(int id) async {
    try {
      final res = await _dio.get('/course-subjects/$id');
      return CourseSubjectDetail.fromJson(_asMap(res.data));
    } catch (e) {
      throw toCourseEvaluationException(e);
    }
  }

  Future<CourseEvaluationResolveResult> resolve({
    required String courseName,
    required String teacherName,
  }) async {
    try {
      final res = await _dio.get(
        '/course-subjects/resolve',
        queryParameters: {
          'course_name': courseName,
          'teacher_name': teacherName,
        },
      );
      return CourseEvaluationResolveResult.fromJson(_asMap(res.data));
    } catch (e) {
      throw toCourseEvaluationException(e);
    }
  }

  /// 提交或复用当前用户的评价记录。
  Future<CourseEvaluationSubmission> submit({
    required String courseName,
    required String teacherName,
    required int star,
    required String comment,
    int? courseSubjectId,
    int? teacherId,
  }) async {
    try {
      final res = await _dio.post(
        '/course-evaluations',
        data: _buildPayload(
          courseName: courseName,
          teacherName: teacherName,
          star: star,
          comment: comment,
          courseSubjectId: courseSubjectId,
          teacherId: teacherId,
        ),
      );
      return CourseEvaluationSubmission.fromJson(_asMap(res.data));
    } catch (e) {
      throw toCourseEvaluationException(e);
    }
  }

  /// 编辑既有记录。revision 用于检测并发修改。
  Future<CourseEvaluationSubmission> update({
    required int id,
    required String courseName,
    required String teacherName,
    required int star,
    required String comment,
    required int revision,
    int? courseSubjectId,
    int? teacherId,
  }) async {
    try {
      final res = await _dio.patch(
        '/user/course-evaluations/$id',
        data: _buildPayload(
          courseName: courseName,
          teacherName: teacherName,
          star: star,
          comment: comment,
          courseSubjectId: courseSubjectId,
          teacherId: teacherId,
          revision: revision,
        ),
      );
      return CourseEvaluationSubmission.fromJson(_asMap(res.data));
    } catch (e) {
      throw toCourseEvaluationException(e);
    }
  }

  Future<CourseEvaluationPage> listMine({int? limit, String? cursor}) async {
    try {
      final res = await _dio.get(
        '/user/course-evaluations',
        queryParameters: _pageParams(limit, cursor),
      );
      return CourseEvaluationPage.fromJson(_asMap(res.data));
    } catch (e) {
      throw toCourseEvaluationException(e);
    }
  }

  Future<CourseEvaluationPage> listPending({int? limit, String? cursor}) async {
    try {
      final res = await _dio.get(
        '/admin/course-evaluations/pending',
        queryParameters: _pageParams(limit, cursor),
      );
      return CourseEvaluationPage.fromJson(_asMap(res.data));
    } catch (e) {
      throw toCourseEvaluationException(e);
    }
  }

  Future<CourseEvaluationSubmission> approve({
    required int id,
    required int revision,
  }) async {
    try {
      final res = await _dio.put(
        '/admin/course-evaluations/$id/approve',
        data: {'revision': revision},
      );
      return CourseEvaluationSubmission.fromJson(_asMap(res.data));
    } catch (e) {
      throw toCourseEvaluationException(e);
    }
  }

  Future<CourseEvaluationSubmission> reject({
    required int id,
    required int revision,
    required String reason,
  }) async {
    try {
      final res = await _dio.put(
        '/admin/course-evaluations/$id/reject',
        data: {'revision': revision, 'reason': reason},
      );
      return CourseEvaluationSubmission.fromJson(_asMap(res.data));
    } catch (e) {
      throw toCourseEvaluationException(e);
    }
  }

  /// 只允许出现白名单字段，从源头杜绝课表私有信息外泄。
  Map<String, dynamic> _buildPayload({
    required String courseName,
    required String teacherName,
    required int star,
    required String comment,
    int? courseSubjectId,
    int? teacherId,
    int? revision,
  }) {
    final payload = <String, dynamic>{
      'course_name': courseName,
      'teacher_name': teacherName,
      'star': star,
      'comment': comment,
    };
    if (courseSubjectId != null) {
      payload['course_subject_id'] = courseSubjectId;
    }
    if (teacherId != null) {
      payload['teacher_id'] = teacherId;
    }
    if (revision != null) {
      payload['revision'] = revision;
    }
    return payload;
  }

  Map<String, dynamic> _pageParams(int? limit, String? cursor) {
    final params = <String, dynamic>{};
    if (limit != null && limit > 0) params['limit'] = limit;
    if (cursor != null && cursor.isNotEmpty) params['cursor'] = cursor;
    return params;
  }

  Map<String, dynamic> _asMap(Object? data) =>
      data is Map<String, dynamic> ? data : <String, dynamic>{};
}

/// 把 Dio 异常归一为稳定业务码，供上层映射到已有状态。
CourseEvaluationException toCourseEvaluationException(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map) {
      final code = data['code']?.toString();
      if (code != null && code.isNotEmpty) {
        return CourseEvaluationException(
          code,
          data['error']?.toString() ?? '课程评价请求失败',
        );
      }
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return const CourseEvaluationException(
          CourseEvaluationErrorCodes.networkUnavailable,
          '网络不可用，请稍后重试',
        );
      default:
        break;
    }
    final status = error.response?.statusCode;
    if (status == 404) {
      return const CourseEvaluationException(
        CourseEvaluationErrorCodes.notFound,
        '评价记录不存在',
      );
    }
    if (status == 403) {
      return const CourseEvaluationException(
        CourseEvaluationErrorCodes.forbidden,
        '无权进行该操作',
      );
    }
  }
  return const CourseEvaluationException(
    CourseEvaluationErrorCodes.unavailable,
    '课程评价服务暂不可用',
  );
}
