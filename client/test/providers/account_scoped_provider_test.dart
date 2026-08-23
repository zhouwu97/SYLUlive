import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/major_provider.dart';
import 'package:shenliyuan/providers/social_provider.dart';
import 'package:shenliyuan/providers/teacher_provider.dart';

class _Adapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _Adapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(String body, int status) {
  return ResponseBody.fromString(
    body,
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

Dio _dio(Future<ResponseBody> Function(RequestOptions options) handler) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.httpClientAdapter = _Adapter(handler);
  return dio;
}

String _majorDetail({required int majorId}) => '''
{
  "major": {"id": $majorId, "name": "计算机科学", "level": "本科"},
  "ratings": [{"id": 11, "major_id": $majorId, "user_id": 101,
    "star": 5, "comment": "评价", "my_vote": "up", "is_own": true}],
  "my_rating": {"id": 11, "major_id": $majorId, "user_id": 101,
    "star": 5, "comment": "评价", "is_own": true},
  "rating_count": 1,
  "average_star": 5
}
''';

String _teacherDetail({required int teacherId}) => '''
{
  "teacher": {"id": $teacherId, "name": "张老师", "course": "高等数学",
    "created_at": "2026-01-01T00:00:00Z"},
  "ratings": [{"id": 21, "teacher_id": $teacherId, "user_id": 101,
    "star": 4, "comment": "评价", "my_vote": "down", "is_own": true}],
  "my_rating": {"id": 21, "teacher_id": $teacherId, "user_id": 101,
    "star": 4, "comment": "评价", "is_own": true},
  "rating_count": 1,
  "average_star": 4
}
''';

void main() {
  test('专业详情切换账号会清除 myRating/myVote，并阻止旧详情可见', () async {
    final provider = MajorProvider(
      _dio((_) async => _json(_majorDetail(majorId: 7), 200)),
    );
    provider.syncSessionUser(101);
    await provider.loadDetail(7);
    expect(provider.myRating, isNotNull);
    expect(provider.ratings.single.myVote, 'up');

    provider.syncSessionUser(202);

    expect(provider.selected, isNull);
    expect(provider.ratings, isEmpty);
    expect(provider.myRating, isNull);
  });

  test('专业详情失败会清除上一专业数据并暴露错误状态', () async {
    var calls = 0;
    final provider = MajorProvider(
      _dio((_) async {
        calls++;
        return calls == 1
            ? _json(_majorDetail(majorId: 7), 200)
            : _json('{"error":"offline"}', 500);
      }),
    );
    provider.syncSessionUser(101);
    await provider.loadDetail(7);
    await provider.loadDetail(8);

    expect(provider.selected, isNull);
    expect(provider.ratings, isEmpty);
    expect(provider.myRating, isNull);
    expect(provider.errorMessage, isNotNull);
  });

  test('教师详情切换账号会清除旧账号个性化评价状态', () async {
    final provider = TeacherProvider(
      _dio((_) async => _json(_teacherDetail(teacherId: 3), 200)),
    );
    provider.syncSessionUser(101);
    await provider.loadTeacherDetail(3);
    expect(provider.detailOf(3).myRating, isNotNull);
    expect(provider.detailOf(3).ratings.single.myVote, 'down');

    provider.syncSessionUser(202);

    expect(provider.detailOf(3).teacher, isNull);
    expect(provider.detailOf(3).myRating, isNull);
    expect(provider.detailOf(3).ratings, isEmpty);
  });

  test('社交网络失败抛出错误而不是返回空列表', () async {
    final provider = SocialProvider(
      _dio((_) async => _json('{"error":"offline"}', 500)),
    );

    await expectLater(
      provider.getFollowers(7),
      throwsA(isA<SocialRequestException>()),
    );
    await expectLater(
      provider.getUserPosts(7),
      throwsA(isA<SocialRequestException>()),
    );
  });
}
