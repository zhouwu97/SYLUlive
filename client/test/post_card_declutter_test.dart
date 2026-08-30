import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/poll.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/widgets/post_card.dart';
import 'package:shenliyuan/widgets/poll/poll_post_card.dart';

class _CardAuthProvider extends ChangeNotifier implements AuthProvider {
  _CardAuthProvider({required this.loggedIn});

  final bool loggedIn;

  @override
  User? get user => null;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  int get sessionGeneration => 0;

  @override
  Dio get dio => Dio();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Post _post({
  int boardId = 1,
  int creditScore = 95,
  int viewCount = 9999,
  bool pinned = false,
  bool featured = false,
}) {
  return Post(
    id: 1,
    title: '测试帖子标题',
    content: '测试帖子内容正文',
    boardId: boardId,
    authorId: 1,
    author: User(
      id: 1,
      studentId: '1',
      nickname: '作者昵称',
      creditScore: creditScore,
      createdAt: DateTime(2026),
    ),
    createdAt: DateTime(2026, 8, 1),
    isPinned: pinned,
    isFeatured: featured,
    viewCount: viewCount,
    likeCount: 12,
    replyCount: 3,
  );
}

Post _pollPost() {
  final now = DateTime.utc(2026, 7, 18);
  return Post(
    id: 2,
    title: '投票主题',
    content: '说明',
    boardId: 1,
    authorId: 2,
    postType: 'poll',
    contentKind: 'poll',
    createdAt: now,
    pollMeta: PollMeta(
      id: 1,
      postId: 2,
      category: 'other',
      selectionMode: 'single',
      maxChoices: 1,
      resultsVisibility: 'always',
      allowChange: false,
      status: 'active',
      effectiveStatus: 'active',
      endsAt: now.add(const Duration(days: 1)),
      remainingSeconds: 3600,
      participantCount: 5,
      hasVoted: false,
      resultsVisible: false,
      canVote: true,
      canChange: false,
      isOwner: false,
      options: const [
        PollOption(id: 10, text: '选项一', sortOrder: 0),
        PollOption(id: 11, text: '选项二', sortOrder: 1),
      ],
    ),
  );
}

Future<void> _pumpPostCard(WidgetTester tester, Post post) async {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: <dynamic>[],
          ),
        );
      },
    ),
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(
          value: _CardAuthProvider(loggedIn: true),
        ),
        ChangeNotifierProvider<PostProvider>.value(
          value: PostProvider(dio, enableCache: false),
        ),
        ChangeNotifierProvider<ThemeProvider>.value(
          value: ThemeProvider(loadOnStart: false),
        ),
        ChangeNotifierProvider<WaterSectionProvider>.value(
          value: WaterSectionProvider(null),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(body: PostCard(post: post)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _PollService extends PollService {
  _PollService() : super(Dio());

  @override
  Future<Post> putBallot(int pollId, List<int> optionIds,
          {String? idempotencyKey}) async =>
      _pollPost();
}

void main() {
  testWidgets('帖子卡片不再显示信用分与等级徽标，查看数恢复显示', (tester) async {
    await _pumpPostCard(tester, _post(boardId: 2, creditScore: 95));

    expect(find.textContaining('%'), findsNothing, reason: '信用分应下沉详情');
    expect(find.text('9999'), findsOneWidget, reason: '查看数应保留在卡片上');
    expect(find.textContaining('Lv.'), findsNothing, reason: '经验等级徽标应移除');

    // 主视觉仍保留：昵称、时间、标题、正文、点赞、评论。
    expect(find.text('作者昵称'), findsOneWidget);
    expect(find.text('测试帖子标题'), findsOneWidget);
    expect(find.text('测试帖子内容正文'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.byKey(const ValueKey('post-card-like')), findsOneWidget);
    expect(find.byKey(const ValueKey('post-card-comment')), findsOneWidget);
  });

  testWidgets('置顶与精华徽标必须保留', (tester) async {
    await _pumpPostCard(
      tester,
      _post(boardId: 1, pinned: true, featured: true),
    );
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('精华'), findsOneWidget);
  });

  testWidgets('投票卡片的校园投票身份只出现一次（不重复副标题）', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => PollProvider(_PollService()),
        child: MaterialApp(
          home: Scaffold(body: PollPostCard(post: _pollPost())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 右上角身份徽标保留。
    expect(find.text('校园投票'), findsOneWidget);
    // 副标题不再拼上「· 校园投票」，避免重复文案。
    expect(
      find.textContaining('· 校园投票'),
      findsNothing,
      reason: '副标题不应重复版块/身份描述',
    );
  });
}
