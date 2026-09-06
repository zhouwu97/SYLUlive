import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/models/topic.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/publish/market_publish_form.dart';
import 'package:image_picker/image_picker.dart';

class _FakeAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  @override
  User? get user => User(
        id: 1,
        studentId: '123456',
        nickname: '测试用户',
        avatar: '',
        createdAt: DateTime(2026, 1, 1),
        studentVerified: true,
        eduBound: true,
      );
}

class _FakePostProvider extends Fake
    with ChangeNotifier
    implements PostProvider {
  int createPostCalls = 0;
  int updatePostCalls = 0;
  String? lastContent;
  String? lastContactType;
  String? lastContact;
  List<int>? lastFileIds;
  List<String>? lastMarketTags;

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
    lastContactType = contactType;
    lastContact = contact;
    lastFileIds = fileIds;
    lastMarketTags = marketTags;
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
    lastContactType = contactType;
    lastContact = contact;
    lastFileIds = fileIds;
    lastMarketTags = marketTags;
    return const CreatePostResult(success: true);
  }

  @override
  Future<int?> uploadImage(XFile file,
          {void Function(int sent, int total)? onProgress}) async =>
      1;
}

Widget _buildMarketForm({
  _FakePostProvider? postProvider,
  MarketPublishForm? form,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => _FakeAuthProvider(),
      ),
      ChangeNotifierProvider<PostProvider>.value(
        value: postProvider ?? _FakePostProvider(),
      ),
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'NotoSansCJKsc',
      ),
      home: form ?? const MarketPublishForm(defaultPostType: 'sell'),
    ),
  );
}

void main() {
  Future<void> fillRequiredMarketFields(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(0), '出一台显示器');
    await tester.enterText(find.byType(TextFormField).at(1), '99');
    await tester.enterText(find.byType(TextFormField).at(2), '成色很好，无坏点');
  }

  Future<void> selectContactType(WidgetTester tester, String label) async {
    await tester
        .ensureVisible(find.byKey(const ValueKey('market-contact-type')));
    await tester.tap(find.byKey(const ValueKey('market-contact-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> addLocalImage(WidgetTester tester) async {
    final dynamic state = tester.state(find.byType(MarketPublishForm));
    state.onImageAdded(XFile('/tmp/market-publish-form-test.png'));
    await tester.pump();
  }

  testWidgets('发布商品时把点亮的描述选项作为 marketTags 提交', (tester) async {
    final postProvider = _FakePostProvider();

    await tester.pumpWidget(_buildMarketForm(postProvider: postProvider));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('自提'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自提'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), '出一台显示器');
    await tester.enterText(find.byType(TextFormField).at(1), '99');
    await tester.enterText(find.byType(TextFormField).at(2), '成色很好，无坏点');
    await addLocalImage(tester);
    await tester.tap(find.text('发布出售').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(postProvider.createPostCalls, 1);
    expect(postProvider.lastContent, '成色很好，无坏点');
    expect(postProvider.lastMarketTags, ['自提']);
  });

  testWidgets('选择微信并输入账号后提交结构化联系方式', (tester) async {
    final postProvider = _FakePostProvider();
    await tester.pumpWidget(_buildMarketForm(postProvider: postProvider));
    await tester.pumpAndSettle();

    await fillRequiredMarketFields(tester);
    await addLocalImage(tester);
    await selectContactType(tester, '微信');
    await tester.enterText(
      find.byKey(const ValueKey('market-contact-value')),
      'wx_123',
    );
    await tester.tap(find.text('发布出售').last);
    await tester.pumpAndSettle();

    expect(postProvider.createPostCalls, 1);
    expect(postProvider.lastContactType, 'wechat');
    expect(postProvider.lastContact, 'wx_123');
  });

  testWidgets('普通商品无图时阻止发布并显示图片必填提示', (tester) async {
    final postProvider = _FakePostProvider();
    await tester.pumpWidget(_buildMarketForm(postProvider: postProvider));
    await tester.pumpAndSettle();

    await fillRequiredMarketFields(tester);
    await tester.tap(find.text('发布出售').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(postProvider.createPostCalls, 0);
    expect(
      find.byKey(const ValueKey('market-image-required-error')),
      findsOneWidget,
    );
    expect(find.text('请至少上传 1 张商品图片'), findsOneWidget);
  });

  testWidgets('曝光帖子无图仍可提交', (tester) async {
    final postProvider = _FakePostProvider();
    await tester.pumpWidget(
      _buildMarketForm(
        postProvider: postProvider,
        form: const MarketPublishForm(defaultPostType: 'exposure'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('证据图片（选填）'), findsOneWidget);
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.minLines == 4,
      ),
      '请核实这条曝光说明',
    );
    await tester.tap(find.text('提交曝光').last);
    await tester.pumpAndSettle();

    expect(postProvider.createPostCalls, 1);
    expect(postProvider.lastFileIds, isNull);
  });

  testWidgets('输入账号但未选择类型时阻止提交', (tester) async {
    final postProvider = _FakePostProvider();
    await tester.pumpWidget(_buildMarketForm(postProvider: postProvider));
    await tester.pumpAndSettle();

    await fillRequiredMarketFields(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('market-contact-value')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('market-contact-value')),
      'wx_123',
    );
    await tester.tap(find.text('发布出售').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(postProvider.createPostCalls, 0);
    expect(find.text('请选择联系方式类型'), findsOneWidget);
  });

  testWidgets('选择类型但未输入账号时阻止提交', (tester) async {
    final postProvider = _FakePostProvider();
    await tester.pumpWidget(_buildMarketForm(postProvider: postProvider));
    await tester.pumpAndSettle();

    await fillRequiredMarketFields(tester);
    await selectContactType(tester, '微信');
    await tester.tap(find.text('发布出售').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(postProvider.createPostCalls, 0);
    expect(find.text('请输入微信号'), findsWidgets);
  });

  testWidgets('编辑商品时回填已选择的描述选项', (tester) async {
    final post = Post(
      id: 1,
      title: '显示器',
      content: '成色很好',
      boardId: 2,
      authorId: 1,
      postType: 'sell',
      price: 99,
      marketTags: const ['自提', '可小刀'],
      createdAt: DateTime(2026, 7, 3),
    );

    await tester.pumpWidget(
      _buildMarketForm(form: MarketPublishForm(editingPost: post)),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(find.text('自提')).style?.color,
        const Color(0xFFFF7A45));
    expect(tester.widget<Text>(find.text('可小刀')).style?.color,
        const Color(0xFFFF7A45));
    expect(tester.widget<Text>(find.text('急出')).style?.color,
        const Color(0xFF747B82));
  });

  testWidgets('编辑商品时回填联系方式类型和账号', (tester) async {
    final post = Post(
      id: 2,
      title: '显示器',
      content: '成色很好',
      boardId: 2,
      authorId: 1,
      postType: 'sell',
      price: 99,
      contactType: 'wechat',
      contact: 'wx_123',
      createdAt: DateTime(2026, 7, 3),
    );

    await tester.pumpWidget(
      _buildMarketForm(form: MarketPublishForm(editingPost: post)),
    );
    await tester.pumpAndSettle();

    final selector = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('market-contact-type')),
    );
    final input = tester.widget<TextFormField>(
      find.byKey(const ValueKey('market-contact-value')),
    );
    expect(selector.initialValue, 'wechat');
    expect(input.controller?.text, 'wx_123');
  });

  testWidgets('只修改联系方式类型也会触发草稿保护', (tester) async {
    final post = Post(
      id: 3,
      title: '显示器',
      content: '成色很好',
      boardId: 2,
      authorId: 1,
      postType: 'sell',
      price: 99,
      contactType: 'wechat',
      contact: '123456789',
      createdAt: DateTime(2026, 7, 3),
    );

    await tester.pumpWidget(
      _buildMarketForm(form: MarketPublishForm(editingPost: post)),
    );
    await tester.pumpAndSettle();
    await selectContactType(tester, 'QQ');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('放弃编辑？'), findsOneWidget);
  });

  testWidgets('编辑商品保留已有图片时可以保存', (tester) async {
    final postProvider = _FakePostProvider();
    final post = Post(
      id: 4,
      title: '显示器',
      content: '成色很好',
      boardId: 2,
      authorId: 1,
      postType: 'sell',
      price: 99,
      images: [PostImage(id: 40, postId: 4, fileId: 400)],
      createdAt: DateTime(2026, 7, 3),
    );

    await tester.pumpWidget(
      _buildMarketForm(
        postProvider: postProvider,
        form: MarketPublishForm(editingPost: post),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存修改').last);
    await tester.pumpAndSettle();

    expect(postProvider.updatePostCalls, 1);
    expect(postProvider.lastFileIds, [400]);
  });

  testWidgets('编辑商品删除最后一张图片时阻止保存', (tester) async {
    final postProvider = _FakePostProvider();
    final post = Post(
      id: 5,
      title: '显示器',
      content: '成色很好',
      boardId: 2,
      authorId: 1,
      postType: 'sell',
      price: 99,
      images: [PostImage(id: 50, postId: 5, fileId: 500)],
      createdAt: DateTime(2026, 7, 3),
    );

    await tester.pumpWidget(
      _buildMarketForm(
        postProvider: postProvider,
        form: MarketPublishForm(editingPost: post),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.tap(find.text('保存修改').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(postProvider.updatePostCalls, 0);
    expect(
      find.byKey(const ValueKey('market-image-required-error')),
      findsOneWidget,
    );
  });
}
