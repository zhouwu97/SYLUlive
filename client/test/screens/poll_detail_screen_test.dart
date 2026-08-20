import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/screens/poll/poll_detail_screen.dart';
import 'package:shenliyuan/widgets/post_reply/post_reply_list.dart';

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
          {
            'id': 10,
            'text': '选项一',
            'sort_order': 0,
            'vote_count': 0,
            'ratio': 0
          }
        ],
      },
    };

Map<String, dynamic> _replyJson() => {
      'id': 21,
      'post_id': 1,
      'author_id': 7,
      'content': '这是统一后的评论',
      'created_at': DateTime.now()
          .subtract(const Duration(minutes: 3))
          .toUtc()
          .toIso8601String(),
      'author': {
        'id': 7,
        'nickname': '测试同学',
        'avatar': '',
        'exp': 2500,
      },
    };

Widget _buildScreen(Dio dio, {Post? initialPost}) {
  final auth = AuthProvider(dio, loadStoredAuth: false);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: auth),
      ChangeNotifierProvider(create: (_) => PollProvider(PollService(dio))),
      ChangeNotifierProvider(create: (_) => PostProvider(dio)),
    ],
    child: MaterialApp(
      home: PollDetailScreen(pollId: 1, initialPost: initialPost),
    ),
  );
}

void main() {
  testWidgets('评论接口失败时投票主体仍然显示', (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/polls/1') {
        handler.resolve(Response(
            requestOptions: options, statusCode: 200, data: _pollJson()));
      } else {
        handler.reject(DioException(
            requestOptions: options, type: DioExceptionType.connectionError));
      }
    }));
    await tester.pumpWidget(_buildScreen(dio));
    await tester.pumpAndSettle();
    expect(find.text('评论失败也应显示投票'), findsOneWidget);
    expect(find.text('投票不存在或已删除'), findsNothing);
  });

  testWidgets('投票详情始终显示完整评论栏且默认不聚焦', (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/polls/1') {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: _pollJson(),
          ),
        );
        return;
      }
      if (options.path == '/posts/1/replies') {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: const {
              'replies': <dynamic>[],
              'total': 0,
              'next_cursor': '',
            },
          ),
        );
        return;
      }
      handler.reject(DioException(requestOptions: options));
    }));

    await tester.pumpWidget(_buildScreen(dio));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('post-reply-image-button')), findsOneWidget);
    final input = find.byKey(const ValueKey('post-reply-input'));
    expect(input, findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-emoji-button')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('post-reply-send-button')), findsOneWidget);
    expect(tester.widget<TextField>(input).focusNode?.hasFocus, isFalse);
  });

  testWidgets('主体加载失败时展示错误和重试，而不是误报不存在', (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/posts/1/replies') {
        handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: const {
          'replies': <dynamic>[],
          'total': 0,
          'next_cursor': '',
        }));
        return;
      }
      handler.reject(DioException(
        requestOptions: options,
        response: Response(
          requestOptions: options,
          statusCode: 503,
          data: {'code': 'temporarily_unavailable', 'error': '服务暂时不可用'},
        ),
      ));
    }));
    await tester.pumpWidget(_buildScreen(dio));
    await tester.pumpAndSettle();
    expect(find.text('服务暂时不可用'), findsOneWidget);
    expect(find.text('投票不存在或已删除'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('刷新失败时保留已有投票并显示顶部错误', (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/posts/1/replies') {
        handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: const {
          'replies': <dynamic>[],
          'total': 0,
          'next_cursor': '',
        }));
        return;
      }
      handler.reject(DioException(
        requestOptions: options,
        response: Response(
          requestOptions: options,
          statusCode: 500,
          data: {'code': 'server_error', 'error': '服务端暂时不可用'},
        ),
      ));
    }));
    await tester.pumpWidget(
      _buildScreen(dio, initialPost: Post.fromJson(_pollJson())),
    );
    await tester.pumpAndSettle();
    expect(find.text('评论失败也应显示投票'), findsOneWidget);
    expect(find.text('服务端暂时不可用'), findsOneWidget);
  });

  testWidgets('已有投票数据时优先加载评论再刷新详情', (tester) async {
    final dio = Dio();
    final requestOrder = <String>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requestOrder.add(options.path);
      if (options.path == '/posts/1/replies') {
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: const {
            'replies': <dynamic>[],
            'total': 0,
            'next_cursor': '',
          }),
        );
        return;
      }
      if (options.path == '/polls/1') {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: _pollJson(),
          ),
        );
        return;
      }
      handler.reject(DioException(requestOptions: options));
    }));

    await tester.pumpWidget(
      _buildScreen(dio, initialPost: Post.fromJson(_pollJson())),
    );
    await tester.pumpAndSettle();

    expect(
      requestOrder.take(2),
      orderedEquals(['/posts/1/replies', '/polls/1']),
    );
  });

  testWidgets('投票评论使用普通帖子公共评论项', (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/polls/1') {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: _pollJson(),
          ),
        );
        return;
      }
      if (options.path == '/posts/1/replies') {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'replies': <dynamic>[_replyJson()],
              'total': 1,
              'next_cursor': '',
            },
          ),
        );
        return;
      }
      handler.reject(DioException(requestOptions: options));
    }));

    await tester.pumpWidget(
      _buildScreen(dio, initialPost: Post.fromJson(_pollJson())),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PostReplyItem), findsOneWidget);
    expect(find.text('测试同学'), findsOneWidget);
    expect(find.text('Lv.6'), findsOneWidget);
    expect(find.text('这是统一后的评论'), findsOneWidget);
    expect(find.text('回复'), findsOneWidget);
    expect(find.text('3分钟前'), findsOneWidget);
  });

  testWidgets('评论刷新失败时继续显示已有评论', (tester) async {
    final dio = Dio();
    var replyRequestCount = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/polls/1') {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: _pollJson(),
          ),
        );
        return;
      }
      if (options.path == '/posts/1/replies') {
        replyRequestCount++;
        if (replyRequestCount == 1) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'replies': <dynamic>[_replyJson()],
                'total': 1,
                'next_cursor': '',
              },
            ),
          );
        } else {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 503,
                data: {'error': '评论服务暂时不可用'},
              ),
            ),
          );
        }
        return;
      }
      handler.reject(DioException(requestOptions: options));
    }));

    await tester.pumpWidget(
      _buildScreen(dio, initialPost: Post.fromJson(_pollJson())),
    );
    await tester.pumpAndSettle();
    expect(find.text('这是统一后的评论'), findsOneWidget);

    await tester.drag(find.byType(ListView).first, const Offset(0, 560));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(replyRequestCount, 2);
    expect(find.text('这是统一后的评论'), findsOneWidget);
    expect(find.textContaining('刷新失败，仍显示上次评论'), findsOneWidget);
  });
}
