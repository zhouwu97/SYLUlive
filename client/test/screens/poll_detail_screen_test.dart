import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/screens/poll/poll_detail_screen.dart';

Map<String, dynamic> _pollJson() => {
      'id': 1,
      'title': '评论失败也应显示投票',
      'content': '主体接口成功',
      'board_id': 1,
      'author_id': 2,
      'post_type': 'poll',
      'content_kind': 'poll',
      'created_at': '2026-07-18T12:00:00Z',
      'poll_meta': {
        'id': 1,
        'post_id': 1,
        'category': 'other',
        'selection_mode': 'single',
        'max_choices': 1,
        'results_visibility': 'always',
        'allow_change': true,
        'status': 'active',
        'effective_status': 'active',
        'ends_at': '2026-07-20T12:00:00Z',
        'remaining_seconds': 3600,
        'participant_count': 0,
        'has_voted': false,
        'results_visible': true,
        'can_vote': false,
        'can_change': false,
        'is_owner': false,
        'options': [
          {'id': 10, 'text': '选项一', 'sort_order': 0, 'vote_count': 0, 'ratio': 0}
        ],
      },
    };

void main() {
  testWidgets('评论接口失败时投票主体仍然显示', (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/polls/1') {
        handler.resolve(Response(requestOptions: options, statusCode: 200, data: _pollJson()));
      } else {
        handler.reject(DioException(requestOptions: options, type: DioExceptionType.connectionError));
      }
    }));
    final auth = AuthProvider(dio, loadStoredAuth: false);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => PollProvider(PollService(dio))),
          ChangeNotifierProvider(create: (_) => PostProvider(dio)),
        ],
        child: const MaterialApp(home: PollDetailScreen(pollId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('评论失败也应显示投票'), findsOneWidget);
    expect(find.text('投票不存在或已删除'), findsNothing);
  });
}
