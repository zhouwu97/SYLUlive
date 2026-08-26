import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/models/topic.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/publish/water_post_composer.dart';
import 'package:shenliyuan/services/post_draft_service.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:image_picker/image_picker.dart';

class FakeAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  FakeAuthProvider({this.userId = 1, this.sessionEpoch = 1});

  int? userId;
  int sessionEpoch;

  @override
  Dio get dio => Dio();

  @override
  User? get user => userId == null
      ? null
      : User(
          id: userId!,
          studentId: '123456',
          nickname: '测试用户',
          avatar: '',
          createdAt: DateTime(2026, 1, 1),
        );

  @override
  int get accountSessionEpoch => sessionEpoch;

  void switchAccount(int? id) {
    userId = id;
    sessionEpoch++;
    notifyListeners();
  }
}

class FakePostProvider extends Fake
    with ChangeNotifier
    implements PostProvider {
  int createPostCalls = 0;
  int updatePostCalls = 0;
  String? lastContent;
  String? lastTitle;
  List<TopicSelection>? lastTopics;
  Completer<CreatePostResult>? createPostCompleter;

  @override
  Post? postFor(int postId) => null;

  @override
  Future<CreatePostResult> createPost({
    required int boardId,
    required String content,
    String? title,
    String? postType,
    int? waterTagId,
    double? price,
    String? contactType,
    String? contact,
    List<int>? fileIds,
    List<String>? marketTags,
    int? teamNeededCount,
    List<String>? teamRoles,
    DateTime? teamDeadline,
    List<TopicSelection>? topics,
  }) async {
    createPostCalls++;
    lastContent = content;
    lastTitle = title;
    lastTopics = topics;
    final completer = createPostCompleter;
    if (completer != null) return completer.future;
    return const CreatePostResult(success: true);
  }

  @override
  Future<CreatePostResult> updatePost({
    required int postId,
    required int boardId,
    required String content,
    String? title,
    String? postType,
    int? waterTagId,
    double? price,
    String? contactType,
    String? contact,
    List<int>? fileIds,
    List<String>? marketTags,
    int? teamNeededCount,
    List<String>? teamRoles,
    DateTime? teamDeadline,
    bool sendTeamFields = false,
    bool sendWaterTagField = false,
    List<TopicSelection>? topics,
  }) async {
    updatePostCalls++;
    lastContent = content;
    lastTitle = title;
    lastTopics = topics;
    return const CreatePostResult(success: true);
  }

  @override
  Future<int?> uploadImage(XFile file,
          {void Function(int sent, int total)? onProgress}) async =>
      1;
}

Widget buildComposerTestApp(
  FakePostProvider postProvider, {
  FakeAuthProvider? authProvider,
  Post? editingPost,
}) {
  final auth = authProvider ?? FakeAuthProvider();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => auth,
      ),
      ChangeNotifierProvider<PostProvider>.value(
        value: postProvider,
      ),
      ChangeNotifierProvider<WaterSectionProvider>(
        create: (_) => WaterSectionProvider(null),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'NotoSansCJKsc',
      ),
      home: WaterPostComposer(editingPost: editingPost),
    ),
  );
}

Widget buildComposerNavigationTestApp(
  FakePostProvider postProvider, {
  FakeAuthProvider? authProvider,
}) {
  final auth = authProvider ?? FakeAuthProvider();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(create: (_) => auth),
      ChangeNotifierProvider<PostProvider>.value(value: postProvider),
      ChangeNotifierProvider<WaterSectionProvider>(
        create: (_) => WaterSectionProvider(null),
      ),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const WaterPostComposer(),
                ),
              ),
              child: const Text('打开发布页'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  testWidgets('成功发布后下一次打开发布页不恢复已发布草稿', (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerNavigationTestApp(postProvider));
    await tester.tap(find.text('打开发布页'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '这条内容已经发布');
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });

    expect(find.byType(WaterPostComposer), findsNothing);
    expect(await PostDraftService().load(), isNull);
  });

  testWidgets('发布请求完成前切换账号不会执行旧账号成功回调', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final auth = FakeAuthProvider();
    final postProvider = FakePostProvider();
    final createCompleter = Completer<CreatePostResult>();
    postProvider.createPostCompleter = createCompleter;

    await tester.pumpWidget(
      buildComposerNavigationTestApp(
        postProvider,
        authProvider: auth,
      ),
    );
    await tester.tap(find.text('打开发布页'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '账号 A 准备发布的内容');
    await tester.tap(find.text('发布'));
    await tester.pump();
    expect(postProvider.createPostCalls, 1);

    auth.switchAccount(2);
    createCompleter.complete(const CreatePostResult(success: true));
    await tester.pumpAndSettle();

    expect(find.byType(WaterPostComposer), findsOneWidget);
    expect(find.text('登录状态已变化，本次发布已取消，请重新确认'), findsOneWidget);
  });

  testWidgets('未发布返回后仍恢复草稿', (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerNavigationTestApp(postProvider));
    await tester.tap(find.text('打开发布页'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '暂未发布的草稿');
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    await tester.tap(find.text('打开发布页'));
    await tester.pumpAndSettle();
    final contentEditable =
        tester.widget<EditableText>(find.byType(EditableText).last);
    expect(contentEditable.controller.text, '暂未发布的草稿');
  });

  testWidgets('WaterPostComposer renders compact publishing layout',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerTestApp(postProvider));
    await tester.pumpAndSettle();

    expect(find.text('发布水帖'), findsOneWidget);
    expect(find.text('发布到'), findsOneWidget);
    expect(find.text('版块'), findsNothing);
    expect(find.text('校园生活'), findsOneWidget);
    expect(find.text('今天想分享什么？'), findsNothing);
    expect(find.text('添加标题（选填）'), findsOneWidget);
    expect(find.text('分享校园生活、提问或记录此时此刻···'), findsOneWidget);
    expect(find.text('添加图片'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('0/9'), findsOneWidget);
    expect(find.text('0/2000字'), findsOneWidget);
    expect(find.text('话题'), findsNothing);
    expect(find.text('添加话题'), findsNothing);
    expect(find.text('地点'), findsNothing);
    expect(find.text('发布'), findsOneWidget);
    expect(find.byIcon(Icons.post_add_outlined), findsNothing);
  });

  testWidgets('composer aligns title and content font sizes with water detail',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerTestApp(postProvider));
    await tester.pumpAndSettle();

    final titleEditable =
        tester.widget<EditableText>(find.byType(EditableText).first);
    final contentEditable =
        tester.widget<EditableText>(find.byType(EditableText).last);
    final titleHint = tester.widget<Text>(find.text('添加标题（选填）'));
    final contentHint = tester.widget<Text>(find.text('分享校园生活、提问或记录此时此刻···'));
    final pageTitle = tester.widget<Text>(find.text('发布水帖'));
    final categoryTitle = tester.widget<Text>(find.text('发布到'));
    final selectedCategory = tester.widget<Text>(find.text('校园生活'));

    expect(pageTitle.style?.color, AppColors.textPrimaryLight);
    expect(pageTitle.style?.fontSize, 17);
    expect(categoryTitle.style?.fontSize, lessThanOrEqualTo(18));
    expect(selectedCategory.style?.fontSize, lessThanOrEqualTo(18));
    expect(titleEditable.style.fontSize, 18);
    expect(titleHint.style?.fontSize, 18);
    expect(contentEditable.style.fontSize, 15);
    expect(contentHint.style?.fontSize, 15);
  });

  testWidgets('empty title with content publishes (title optional)',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerTestApp(postProvider));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).last,
      '今天食堂二楼的窗口很好吃',
    );
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();

    expect(postProvider.createPostCalls, 1, reason: '标题可选，有正文即可发布');
  });

  testWidgets('missing content after title shows validation message',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerTestApp(postProvider));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '食堂窗口推荐');
    await tester.tap(find.text('发布'));
    await tester.pump();

    expect(find.text('写点内容再发布吧'), findsOneWidget);
    expect(postProvider.createPostCalls, 0);
  });

  testWidgets('typing content updates limited character counter',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerTestApp(postProvider));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).last,
      '今天食堂二楼的窗口很好吃',
    );
    await tester.pump();

    expect(find.text('12/2000字'), findsOneWidget);
  });

  testWidgets('content input enforces 2000 character limit',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();
    final longContent = List.filled(2001, 'a').join();

    await tester.pumpWidget(buildComposerTestApp(postProvider));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '标题');
    await tester.enterText(find.byType(TextFormField).last, longContent);
    await tester.pump();

    expect(find.text('2000/2000字'), findsOneWidget);

    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();

    expect(postProvider.createPostCalls, 1);
    expect(postProvider.lastContent?.length, 2000);
  });

  testWidgets('submitting with title and content passes title to provider',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerTestApp(postProvider));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '食堂窗口推荐');
    await tester.enterText(
      find.byType(TextFormField).last,
      '今天食堂二楼的窗口很好吃',
    );
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();

    expect(postProvider.createPostCalls, 1);
    expect(postProvider.lastTitle, '食堂窗口推荐');
    expect(postProvider.lastContent, '今天食堂二楼的窗口很好吃');
  });

  testWidgets('publishing does not submit topics_json',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerTestApp(postProvider));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '不再提交话题的内容');
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();

    expect(postProvider.createPostCalls, 1);
    expect(postProvider.lastTopics, isNull);
  });

  testWidgets(
      'editing an old post preserves its topics by omitting topics_json',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();
    final oldPost = Post(
      id: 42,
      content: '历史帖子内容',
      boardId: 1,
      authorId: 1,
      topics: const [Topic(id: 7, name: '历史话题')],
      createdAt: DateTime(2026, 1, 1),
    );

    await tester.pumpWidget(
      buildComposerTestApp(postProvider, editingPost: oldPost),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    expect(postProvider.updatePostCalls, 1);
    expect(postProvider.lastTopics, isNull);
  });
}
