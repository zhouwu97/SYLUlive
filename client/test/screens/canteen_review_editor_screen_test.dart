import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/canteen_review_draft.dart';
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

  testWidgets('自由输入推荐菜品、快捷填入已有菜品与删除标签交互', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1/dishes') {
        return _json(
          '[{"id":1,"canteen_id":1,"name":"牛肉面","status":"active"},{"id":2,"canteen_id":1,"name":"炸酱面","status":"active"}]',
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

    // 1. 验证初始状态：0 / 3，展示快捷推荐
    expect(find.text('0 / 3'), findsOneWidget);
    expect(find.text('大家常推荐（点击快速填入）：'), findsOneWidget);
    expect(find.text('牛肉面'), findsWidgets);

    // 2. 自由文本输入“自创麻辣烫”并点击添加
    final dishInput = find.byKey(const Key('canteen_dish_input'));
    expect(dishInput, findsOneWidget);
    await tester.enterText(dishInput, '自创麻辣烫');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('canteen_dish_add_btn')));
    await tester.pumpAndSettle();

    // 验证添加成功：1 / 3，标签显示“自创麻辣烫”
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('自创麻辣烫'), findsOneWidget);

    // 3. 点击快捷推荐中的“牛肉面”
    final beefNoodleFinder = find.text('牛肉面').first;
    await tester.ensureVisible(beefNoodleFinder);
    await tester.pumpAndSettle();
    await tester.tap(beefNoodleFinder);
    await tester.pumpAndSettle();

    // 验证添加成功：2 / 3
    expect(find.text('2 / 3'), findsOneWidget);

    // 4. 点击“自创麻辣烫”标签的 ❌ 按钮删除
    final closeIcons = find.byIcon(Icons.close_rounded);
    expect(closeIcons, findsNWidgets(2));
    await tester.ensureVisible(closeIcons.first);
    await tester.pumpAndSettle();
    await tester.tap(closeIcons.first);
    await tester.pumpAndSettle();

    // 验证删除后变为 1 / 3
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('自创麻辣烫'), findsNothing);
    expect(find.text('牛肉面'), findsWidgets);
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
      'recommended_dishes': ['老字号牛肉面'],
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
    expect(find.text('老字号牛肉面'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
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

  testWidgets('草稿中的本地图片丢失时阻止发布并保留草稿', (tester) async {
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

    // 预置包含不存在本地图片路径的草稿
    await draftRepository.saveDraft(
      CanteenReviewDraft(
        userId: 101,
        canteenId: 1,
        star: 4,
        comment: '草稿带图测试',
        tags: const ['味道不错'],
        recommendedDishes: const ['牛肉面'],
        images: const [
          CanteenReviewDraftImage(
            type: ReviewDraftImageType.localPending,
            localPath: '/non/existent/path/to/missing_image.jpg',
          ),
        ],
        updatedAt: DateTime.now(),
      ),
    );

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: draftRepository,
      ),
    );
    await tester.pumpAndSettle();

    // 点击发布评价
    await tester.tap(find.widgetWithText(FilledButton, '发布评价'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 500));

    // 验证：阻止调用发布接口
    expect(rateCalled, isFalse);
    // 验证：弹出丢失提示
    expect(find.text('草稿中的图片本地文件已丢失，请重新选择或删除该图片后发布'), findsOneWidget);
    // 验证：草稿仍然保留，未被误删
    final draftAfter = await draftRepository.loadDraft(userId: 101, canteenId: 1);
    expect(draftAfter, isNotNull);
    expect(draftAfter!.comment, '草稿带图测试');
  });

  testWidgets('409 冲突：选择保留草稿并退出，草稿立即落盘且重新进入时完整保留', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1/rate' && options.method == 'POST') {
        return _json('{"code":"rating_conflict","error":"评价已在其他设备更新，请刷新后重试","remote_updated_at":"2026-08-19T20:00:00Z"}', 409);
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

    // 填写评价内容
    await tester.tap(find.byIcon(Icons.star_border_rounded).at(3));
    await tester.enterText(find.byType(TextField).first, '冲突测试中的独家评价');
    await tester.pumpAndSettle();

    // 点击发布，触发 409 冲突
    await tester.tap(find.widgetWithText(FilledButton, '发布评价'));
    await tester.pumpAndSettle();

    // 弹出 409 冲突对话框
    expect(find.text('评价版本冲突'), findsOneWidget);
    expect(find.text('保留草稿并退出'), findsOneWidget);
    expect(find.text('强制覆盖'), findsOneWidget);

    // 点击“保留草稿并退出”
    await tester.tap(find.text('保留草稿并退出'));
    await tester.pumpAndSettle();

    // 验证草稿已被立即落盘
    final savedDraft = await draftRepository.loadDraft(userId: 101, canteenId: 1);
    expect(savedDraft, isNotNull);
    expect(savedDraft!.comment, '冲突测试中的独家评价');
    expect(savedDraft.star, 4);

    // 清空页面后重新进入编辑器，验证草稿完整恢复
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: draftRepository,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('冲突测试中的独家评价'), findsOneWidget);
  });
}

