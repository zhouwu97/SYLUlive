import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
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
        eduBound: true,
      );
}

class _FakePostProvider extends Fake
    with ChangeNotifier
    implements PostProvider {
  int createPostCalls = 0;
  String? lastContent;
  List<String>? lastMarketTags;

  @override
  Future<CreatePostResult> createPost({
    required int boardId,
    required String content,
    String? title,
    String? postType,
    int? waterTagId,
    double? price,
    String? contact,
    List<int>? fileIds,
    List<String>? marketTags,
  }) async {
    createPostCalls++;
    lastContent = content;
    lastMarketTags = marketTags;
    return const CreatePostResult(success: true);
  }

  @override
  Future<int?> uploadImage(XFile file) async => 1;
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
    await tester.tap(find.text('发布出售').last);
    await tester.pumpAndSettle();

    expect(postProvider.createPostCalls, 1);
    expect(postProvider.lastContent, '成色很好，无坏点');
    expect(postProvider.lastMarketTags, ['自提']);
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
        const Color(0xFF4F5AF7));
    expect(tester.widget<Text>(find.text('可小刀')).style?.color,
        const Color(0xFF4F5AF7));
    expect(tester.widget<Text>(find.text('急出')).style?.color,
        const Color(0xFF6F7585));
  });
}
