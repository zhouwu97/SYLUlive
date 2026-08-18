import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_review_editor_screen.dart';
import 'package:shenliyuan/services/canteen_review_draft_repository.dart';

class FakeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) _handler;
  FakeAdapter(this._handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(String body, int status) {
  return ResponseBody.fromString(body, status, headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  });
}

class _FakeAuthProvider extends AuthProvider {
  final User fakeUser;
  final Dio fakeDio;

  _FakeAuthProvider(this.fakeUser, this.fakeDio) : super(fakeDio);

  @override
  User? get user => fakeUser;

  @override
  bool get isLoggedIn => true;

  @override
  bool get isInitialized => true;

  @override
  Dio get dio => fakeDio;
}

Widget _buildEditorTestApp({
  required Dio dio,
  required CanteenReviewDraftRepository draftRepository,
  int canteenId = 1,
  String canteenName = '我家有面(一楼)',
  double averageStar = 5.0,
  int ratingCount = 2,
  int dishCount = 12,
  int dishPhotoCount = 18,
  Map<String, dynamic>? existingRating,
}) {
  final user = User(
    id: 101,
    studentId: '2023001',
    studentVerified: true,
    nickname: '测试小周',
    createdAt: DateTime.now(),
  );
  final authProvider = _FakeAuthProvider(user, dio);

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
      ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
    ],
    child: MaterialApp(
      home: CanteenReviewEditorScreen(
        canteenId: canteenId,
        canteenName: canteenName,
        averageStar: averageStar,
        ratingCount: ratingCount,
        dishCount: dishCount,
        dishPhotoCount: dishPhotoCount,
        existingRating: existingRating,
        draftRepositoryOverride: draftRepository,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryPreferencesStore store;
  late Directory tempDir;
  late CanteenReviewDraftRepository draftRepository;

  setUp(() async {
    store = MemoryPreferencesStore();
    tempDir = await Directory.systemTemp.createTemp('canteen_editor_test_');
    draftRepository = CanteenReviewDraftRepository(
      storeOverride: store,
      baseDirOverride: tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('初始状态与评分打分联动：0星禁用发布，打分后启用并显示评语', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1/dishes') {
        return _json(
          '[{"id":1,"canteen_id":1,"name":"牛肉面","status":"active"}]',
          200,
        );
      }
      return _json('{}', 200);
    });

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: draftRepository,
      ),
    );
    await tester.pumpAndSettle();

    // 验证头卡数据与公开提示
    expect(find.text('我家有面(一楼)'), findsOneWidget);
    expect(find.text('5.0'), findsOneWidget);
    expect(find.text('2人评价'), findsOneWidget);
    expect(find.text('菜品 12 · 实拍 18'), findsOneWidget);
    expect(find.text('评价将公开展示给其他同学'), findsOneWidget);

    // 0 星打分时，发布按钮不可点击
    final publishButtonFinder = find.widgetWithText(FilledButton, '发布评价');
    expect(publishButtonFinder, findsOneWidget);
    final filledBtn = tester.widget<FilledButton>(publishButtonFinder);
    expect(filledBtn.onPressed, isNull);

    // 点击第 5 颗星打分
    final starIcons = find.byIcon(Icons.star_border_rounded);
    expect(starIcons, findsNWidgets(5));
    await tester.tap(starIcons.last);
    await tester.pumpAndSettle();

    expect(find.text('超赞'), findsWidgets);
    final activeBtn = tester.widget<FilledButton>(publishButtonFinder);
    expect(activeBtn.onPressed, isNotNull);
  });

  testWidgets('体验标签多选与上限控制', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async => _json('[]', 200));

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: draftRepository,
      ),
    );
    await tester.pumpAndSettle();

    // 验证白名单标签
    expect(find.text('味道不错'), findsOneWidget);
    expect(find.text('分量足'), findsOneWidget);
    expect(find.text('出餐快'), findsOneWidget);

    // 选中“味道不错”与“分量足”
    await tester.tap(find.text('味道不错'));
    await tester.pumpAndSettle();
    expect(find.text('1/6'), findsOneWidget);

    await tester.tap(find.text('分量足'));
    await tester.pumpAndSettle();
    expect(find.text('2/6'), findsOneWidget);

    // 再次点击取消选中
    await tester.tap(find.text('味道不错'));
    await tester.pumpAndSettle();
    expect(find.text('1/6'), findsOneWidget);
  });

  testWidgets('详细评价字数统计与输入', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async => _json('[]', 200));

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: draftRepository,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '牛肉面面条筋道，汤底浓郁！');
    await tester.pumpAndSettle();

    expect(find.text('13 / 200'), findsOneWidget);
  });

  testWidgets('修改已有评价预填数据，按钮文案为“保存修改”', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async => _json('[]', 200));

    final existing = {
      'id': 99,
      'star': 4,
      'comment': '老评价内容',
      'images': '["/uploads/old_photo.jpg"]',
      'tags': '["taste_good","price_fair"]',
      'recommended_dish_ids': [1],
      'updated_at': '2026-08-01T12:00:00Z',
    };

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: draftRepository,
        existingRating: existing,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('修改评价'), findsOneWidget);
    expect(find.text('老评价内容'), findsOneWidget);
    expect(find.text('很满意'), findsWidgets);
    expect(find.text('2/6'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '保存修改'), findsOneWidget);
  });

  testWidgets('退出保护提示：有修改时拦截并提供保存草稿选项', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async => _json('[]', 200));

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: draftRepository,
      ),
    );
    await tester.pumpAndSettle();

    // 打 4 星，形成 dirty 状态
    await tester.tap(find.byIcon(Icons.star_border_rounded).at(3));
    await tester.pumpAndSettle();

    // 点击返回按钮
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await tester.pumpAndSettle();

    // 弹出退出保护 Sheet
    expect(find.text('保存这次评价？'), findsOneWidget);
    expect(find.text('保存草稿并退出'), findsOneWidget);
    expect(find.text('放弃本次修改'), findsOneWidget);
    expect(find.text('继续编辑'), findsOneWidget);

    // 点击“保存草稿并退出”
    await tester.tap(find.text('保存草稿并退出'));
    await tester.pumpAndSettle();

    // 验证草稿已被持久化
    final loaded = await draftRepository.loadDraft(userId: 101, canteenId: 1);
    expect(loaded, isNotNull);
    expect(loaded!.star, 4);
  });

  testWidgets('成功发布评价后清除草稿并返回 true', (tester) async {
    var rateCalled = false;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1/rate' && options.method == 'POST') {
        rateCalled = true;
        return _json('{"message":"评价已保存"}', 200);
      }
      if (options.path == '/canteens/1/dishes') {
        return _json('[]', 200);
      }
      return _json('{}', 200);
    });

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: draftRepository,
      ),
    );
    await tester.pumpAndSettle();

    // 打 5 星并填写评语
    await tester.tap(find.byIcon(Icons.star_border_rounded).last);
    await tester.enterText(find.byType(TextField).first, '非常好吃，强烈推荐！');
    await tester.pumpAndSettle();

    // 点击发布
    await tester.tap(find.widgetWithText(FilledButton, '发布评价'));
    await tester.pumpAndSettle();

    expect(rateCalled, isTrue);
    // 验证发布后草稿被删除
    final draftAfter = await draftRepository.loadDraft(userId: 101, canteenId: 1);
    expect(draftAfter, isNull);
  });
}
