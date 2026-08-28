import 'dart:async';
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

/// 让指定内容的自动保存停在写入中，覆盖发布删除与自动保存的竞态窗口。
class _BlockingPreferencesStore extends MemoryPreferencesStore {
  final Completer<void> firstMatchingWriteStarted = Completer<void>();
  final Completer<void> releaseFirstMatchingWrite = Completer<void>();
  bool _blocked = false;

  @override
  Future<bool> setString(String key, String value) async {
    if (!_blocked && value.contains('非常好吃，强烈推荐！')) {
      _blocked = true;
      firstMatchingWriteStarted.complete();
      await releaseFirstMatchingWrite.future;
    }
    return super.setString(key, value);
  }
}

Widget _buildEditorTestApp({
  required Dio dio,
  required CanteenReviewDraftRepository draftRepository,
  User? user,
  int canteenId = 1,
  String canteenName = '我家有面(一楼)',
  double averageStar = 5.0,
  int ratingCount = 2,
  int dishCount = 12,
  int dishPhotoCount = 18,
  Map<String, dynamic>? existingRating,
}) {
  final currentUser = user ??
      User(
        id: 101,
        studentId: '2023001',
        studentVerified: true,
        nickname: '测试小周',
        createdAt: DateTime.now(),
      );
  final authProvider = _FakeAuthProvider(currentUser, dio);

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
        mode: existingRating == null
            ? CanteenReviewEditorMode.create
            : CanteenReviewEditorMode.edit,
        existingReview: existingRating,
        draftRepositoryOverride: draftRepository,
      ),
    ),
  );
}

Future<void> _completeDimensions(WidgetTester tester) async {
  const labels = [
    '味道',
    '性价比',
    '排队效率',
    '卫生环境',
    '服务态度',
  ];
  for (final label in labels) {
    final row =
        find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
    final score = find.descendant(of: row, matching: find.text('5'));
    await tester.ensureVisible(score);
    await tester.tap(score);
  }
  await tester.pumpAndSettle();
}

Future<void> _setTasteDimension(WidgetTester tester, int score) async {
  final row =
      find.ancestor(of: find.text('味道'), matching: find.byType(Row)).first;
  final scoreButton = find.descendant(
    of: row,
    matching: find.text('$score'),
  );
  await tester.ensureVisible(scoreButton);
  await tester.tap(scoreButton);
  await tester.pumpAndSettle();
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

  testWidgets('五维评分均为必填，完成后才允许发布', (tester) async {
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

    // 顶部不再重复展示食堂摘要卡，创建态展示数据规则提示。
    expect(find.text('可以再次评价'), findsOneWidget);

    for (final label in [
      '味道',
      '性价比',
      '排队效率',
      '卫生环境',
      '服务态度',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    // 五个维度未完成时，发布按钮不可点击
    final publishButtonFinder = find.widgetWithText(FilledButton, '发布食堂评价');
    expect(publishButtonFinder, findsOneWidget);
    final filledBtn = tester.widget<FilledButton>(publishButtonFinder);
    expect(filledBtn.onPressed, isNull);

    await _completeDimensions(tester);

    expect(find.text('5.00'), findsOneWidget);
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
    final tasteTag = find.text('味道不错');
    await tester.ensureVisible(tasteTag);
    await tester.tap(tasteTag);
    await tester.pumpAndSettle();
    expect(find.text('1/6'), findsOneWidget);

    final portionTag = find.text('分量足');
    await tester.ensureVisible(portionTag);
    await tester.tap(portionTag);
    await tester.pumpAndSettle();
    expect(find.text('2/6'), findsOneWidget);

    // 再次点击取消选中
    await tester.ensureVisible(tasteTag);
    await tester.tap(tasteTag);
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

    await tester.enterText(find.byType(TextField).last, '牛肉面面条筋道，汤底浓郁！');
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

    // 1. 验证初始状态：0 / 1，展示快捷推荐
    expect(find.text('0 / 1'), findsOneWidget);
    expect(find.text('已有菜品（点击快速填入）：'), findsOneWidget);
    expect(find.text('牛肉面'), findsWidgets);

    // 2. 自由文本输入“自创麻辣烫”并点击添加
    final dishInput = find.byKey(const Key('canteen_dish_input'));
    expect(dishInput, findsOneWidget);
    await tester.enterText(dishInput, '自创麻辣烫');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('canteen_dish_add_btn')));
    await tester.pumpAndSettle();

    // 新输入的菜名在本次评价中保留，作为本次菜品随评价一次提交。
    expect(find.text('自创麻辣烫'), findsWidgets);
    expect(find.text('1 / 1'), findsOneWidget);

    // 3. 删除后再从已有菜品中选择“牛肉面”
    var closeIcons = find.byIcon(Icons.close_rounded);
    expect(closeIcons, findsOneWidget);
    await tester.ensureVisible(closeIcons.first);
    await tester.tap(closeIcons.first);
    await tester.pumpAndSettle();
    final beefNoodleFinder = find.text('牛肉面').first;
    await tester.ensureVisible(beefNoodleFinder);
    await tester.pumpAndSettle();
    await tester.tap(beefNoodleFinder);
    await tester.pumpAndSettle();

    // 单条评价只能保留一道菜
    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.text('牛肉面'), findsWidgets);

    // 4. 删除已选择的推荐菜品后恢复为空
    closeIcons = find.byIcon(Icons.close_rounded);
    expect(closeIcons, findsOneWidget);
    await tester.ensureVisible(closeIcons.first);
    await tester.pumpAndSettle();
    await tester.tap(closeIcons.first);
    await tester.pumpAndSettle();

    // 验证删除后恢复为空，快捷推荐仍可再次选择已有菜品
    expect(find.text('0 / 1'), findsOneWidget);
    expect(find.text('牛肉面'), findsWidgets);
  });

  testWidgets('修改已有评价预填数据，按钮文案为“保存修改”', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async => _json('[]', 200));

    final existing = {
      'id': 99,
      'star': 4,
      'comment': '老评价内容',
      'taste_score': 5,
      'value_score': 4,
      'queue_score': 3,
      'hygiene_score': 4,
      'service_score': 5,
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

    expect(find.text('修改食堂评价'), findsOneWidget);
    expect(find.text('老评价内容'), findsOneWidget);
    expect(find.text('4.30'), findsOneWidget);
    expect(find.text('2/6'), findsOneWidget);
    expect(find.text('老字号牛肉面'), findsOneWidget);
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

    // 修改味道维度，形成 dirty 状态
    await _setTasteDimension(tester, 4);

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
    var reviewCalled = false;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1/reviews' && options.method == 'POST') {
        reviewCalled = true;
        return _json('{"review":{"updated_at":"2026-08-20T12:00:00Z"}}', 201);
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

    // 完成五维评分并填写评语
    await _completeDimensions(tester);
    await tester.enterText(find.byType(TextField).last, '非常好吃，强烈推荐！');
    await tester.pumpAndSettle();

    // 点击发布
    await tester.tap(find.widgetWithText(FilledButton, '发布食堂评价'));
    await tester.pumpAndSettle();

    expect(reviewCalled, isTrue);
    // 验证发布后草稿被删除
    final draftAfter =
        await draftRepository.loadDraft(userId: 101, canteenId: 1);
    expect(draftAfter, isNull);
  });

  testWidgets('发布时正在进行的自动保存不会在发布后重新写回草稿', (tester) async {
    var reviewCalled = false;
    final blockingStore = _BlockingPreferencesStore();
    final blockingRepository = CanteenReviewDraftRepository(
      storeOverride: blockingStore,
      baseDirOverride: tempDir,
    );
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1/reviews' && options.method == 'POST') {
        reviewCalled = true;
        return _json('{"review":{"updated_at":"2026-08-20T12:00:00Z"}}', 201);
      }
      if (options.path == '/canteens/1/dishes') {
        return _json('[]', 200);
      }
      return _json('{}', 200);
    });

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: blockingRepository,
      ),
    );
    await tester.pumpAndSettle();

    await _completeDimensions(tester);
    await tester.enterText(find.byType(TextField).last, '非常好吃，强烈推荐！');
    await tester.pump(const Duration(milliseconds: 700));
    await blockingStore.firstMatchingWriteStarted.future;

    await tester.tap(find.widgetWithText(FilledButton, '发布食堂评价'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(reviewCalled, isTrue);

    // 先释放被挂起的自动保存，验证生产代码会等待它完成后再删除草稿。
    blockingStore.releaseFirstMatchingWrite.complete();
    await tester.pumpAndSettle();

    final draftAfter = await blockingRepository.loadDraft(
      userId: 101,
      canteenId: 1,
    );
    expect(draftAfter, isNull);

    // 模拟下一次重新进入创建评价，旧内容不应再次出现。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: blockingRepository,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('非常好吃，强烈推荐！'), findsNothing);
  });

  testWidgets('草稿中的本地图片丢失时阻止发布并保留草稿', (tester) async {
    var reviewCalled = false;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1/reviews' && options.method == 'POST') {
        reviewCalled = true;
        return _json('{"review":{"updated_at":"2026-08-20T12:00:00Z"}}', 201);
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
        recommendedDishes: const [],
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
    await tester.tap(find.widgetWithText(FilledButton, '发布食堂评价'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 500));

    // 验证：阻止调用发布接口
    expect(reviewCalled, isFalse);
    // 验证：弹出丢失提示
    expect(find.text('草稿中的图片本地文件已丢失，请重新选择或删除该图片后发布'), findsOneWidget);
    // 验证：草稿仍然保留，未被误删
    final draftAfter =
        await draftRepository.loadDraft(userId: 101, canteenId: 1);
    expect(draftAfter, isNotNull);
    expect(draftAfter!.comment, '草稿带图测试');
  });

  testWidgets('409 冲突：选择保留草稿并退出，草稿立即落盘且重新进入时完整保留', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/reviews/55' && options.method == 'PATCH') {
        return _json(
            '{"code":"rating_conflict","error":"评价已在其他设备更新，请刷新后重试","remote_updated_at":"2026-08-19T20:00:00Z"}',
            409);
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
        existingRating: {
          'review_event_id': 55,
          'score_version': 2,
          'taste_score': 5,
          'value_score': 4,
          'queue_score': 3,
          'hygiene_score': 4,
          'service_score': 4,
          'updated_at': '2026-08-19T12:00:00Z',
        },
      ),
    );
    await tester.pumpAndSettle();

    // 填写评价内容
    await _completeDimensions(tester);
    await _setTasteDimension(tester, 4);
    await tester.enterText(find.byType(TextField).last, '冲突测试中的独家评价');
    await tester.pumpAndSettle();

    // 点击保存，触发 409 冲突
    await tester.tap(find.widgetWithText(FilledButton, '保存修改'));
    await tester.pumpAndSettle();

    // 弹出 409 冲突对话框
    expect(find.text('评价版本冲突'), findsOneWidget);
    expect(find.text('保留草稿并退出'), findsOneWidget);
    expect(find.text('强制覆盖'), findsOneWidget);

    // 点击“保留草稿并退出”
    await tester.tap(find.text('保留草稿并退出'));
    await tester.pumpAndSettle();

    // 验证草稿已被立即落盘
    final savedDraft = await draftRepository.loadDraft(
      userId: 101,
      canteenId: 1,
      mode: 'edit',
      reviewEventId: 55,
    );
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
        existingRating: {
          'review_event_id': 55,
          'score_version': 2,
          'taste_score': 5,
          'value_score': 4,
          'queue_score': 3,
          'hygiene_score': 4,
          'service_score': 4,
          'updated_at': '2026-08-19T12:00:00Z',
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('冲突测试中的独家评价'), findsOneWidget);
  });

  testWidgets('诚信度与权重根据当前登录用户信息动态展示', (tester) async {
    final dio = Dio();
    dio.httpClientAdapter = FakeAdapter((options) async {
      return _json('{}', 200);
    });
    final draftRepository = CanteenReviewDraftRepository(
      storeOverride: MemoryPreferencesStore(),
    );

    final user = User(
      id: 101,
      studentId: '2023001',
      studentVerified: true,
      nickname: '测试小周',
      creditScore: 100,
      createdAt: DateTime.now(),
    );

    await tester.pumpWidget(
      _buildEditorTestApp(
        dio: dio,
        draftRepository: draftRepository,
        user: user,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('你的诚信度 100 · 权重约 1.0'), findsOneWidget);
  });
}
