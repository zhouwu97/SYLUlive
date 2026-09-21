import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/controllers/post_reply_composer_controller.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/post_reply_service.dart';

void main() {
  test('评论失败不记录，重试成功记录原账号', () async {
    final prefs = MemoryPreferencesStore();
    final recent = EmojiRecentManager(preferencesLoader: () async => prefs)
      ..switchUser('1');
    await recent.load();
    final dio = Dio();
    var fail = true;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (fail) {
        handler.reject(DioException(requestOptions: request));
      } else {
        recent.switchUser('2');
        handler
            .resolve(Response(requestOptions: request, statusCode: 201, data: {
          'id': 1,
          'post_id': 2,
          'author_id': 1,
          'content': '😀',
          'created_at': '2026-09-20T00:00:00Z'
        }));
      }
    }));
    final service = PostReplyService(dio, recentManager: recent);
    const draft = PostReplyDraft(text: '😀');
    await expectLater(service.submit(2, draft), throwsA(isA<DioException>()));
    expect(await recent.load(), isEmpty);
    fail = false;
    await service.submit(2, draft);
    expect(await recent.load(), isEmpty);
    recent.switchUser('1');
    expect((await recent.load()).single.useCount, 1);
  });
}
