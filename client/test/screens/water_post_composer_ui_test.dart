import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/publish/water_post_composer.dart';
import 'package:image_picker/image_picker.dart';

class FakeAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  @override
  User? get user => User(
        id: 1,
        studentId: '123456',
        nickname: '测试用户',
        avatar: '',
        createdAt: DateTime(2026, 1, 1),
      );
}

class FakePostProvider extends Fake
    with ChangeNotifier
    implements PostProvider {
  int createPostCalls = 0;
  String? lastContent;
  String? lastTitle;

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
  }) async {
    createPostCalls++;
    lastContent = content;
    lastTitle = title;
    return const CreatePostResult(success: true);
  }

  @override
  Future<int?> uploadImage(XFile file,
          {void Function(int sent, int total)? onProgress}) async =>
      1;
}

Widget buildComposerTestApp(FakePostProvider postProvider) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => FakeAuthProvider(),
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
      home: const WaterPostComposer(),
    ),
  );
}

void main() {
  testWidgets('WaterPostComposer renders compact publishing layout',
      (WidgetTester tester) async {
    final postProvider = FakePostProvider();

    await tester.pumpWidget(buildComposerTestApp(postProvider));
    await tester.pumpAndSettle();

    expect(find.text('发布水帖'), findsOneWidget);
    expect(find.text('版块'), findsOneWidget);
    expect(find.text('校园生活'), findsOneWidget);
    expect(find.text('今天想分享什么？'), findsNothing);
    expect(find.text('添加标题'), findsOneWidget);
    expect(find.text('添加标题（选填）'), findsNothing);
    expect(find.text('分享校园生活、提问或记录此时此刻···'), findsOneWidget);
    expect(find.text('添加照片'), findsOneWidget);
    expect(find.text('图片 0/9'), findsOneWidget);
    expect(find.text('0/2000字'), findsOneWidget);
    expect(find.text('话题'), findsNothing);
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
    final titleHint = tester.widget<Text>(find.text('添加标题'));
    final contentHint = tester.widget<Text>(find.text('分享校园生活、提问或记录此时此刻···'));
    final pageTitle = tester.widget<Text>(find.text('发布水帖'));
    final categoryTitle = tester.widget<Text>(find.text('版块'));
    final selectedCategory = tester.widget<Text>(find.text('校园生活'));

    expect(pageTitle.style?.color, Colors.black);
    expect(pageTitle.style?.fontSize, 18);
    expect(categoryTitle.style?.fontSize, lessThanOrEqualTo(18));
    expect(selectedCategory.style?.fontSize, lessThanOrEqualTo(18));
    expect(titleEditable.style.fontSize, 18.5);
    expect(titleHint.style?.fontSize, 18.5);
    expect(contentEditable.style.fontSize, 14.5);
    expect(contentHint.style?.fontSize, 14.5);
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
}
