import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/feedback/feedback_detail_screen.dart';

class _FakeImagePickerPlatform extends ImagePickerPlatform {
  bool throwOnPick = false;
  XFile? pickedFile;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    if (throwOnPick) {
      throw PlatformException(code: 'camera_access_denied', message: '相册权限异常');
    }
    return pickedFile;
  }
}

class _MockDetailAuthProvider extends ChangeNotifier implements AuthProvider {
  _MockDetailAuthProvider({required this.client});

  final Dio client;
  int currentUserId = 10;
  int currentSessionGeneration = 1;

  @override
  User? get user => User(
        id: currentUserId,
        studentId: '2026$currentUserId',
        nickname: '学生小明',
        createdAt: DateTime(2026, 9, 14),
      );

  @override
  bool get isLoggedIn => true;

  @override
  int get sessionGeneration => currentSessionGeneration;

  @override
  Dio get dio => client;

  void switchAccount(int userId) {
    currentUserId = userId;
    currentSessionGeneration++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ImagePickerPlatform originalPlatform;
  late _FakeImagePickerPlatform fakePickerPlatform;

  setUp(() {
    originalPlatform = ImagePickerPlatform.instance;
    fakePickerPlatform = _FakeImagePickerPlatform();
    ImagePickerPlatform.instance = fakePickerPlatform;
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPlatform;
  });

  testWidgets('工单初次加载失败后后台恢复成功应退出错误页', (tester) async {
    var attempts = 0;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path != '/feedback/tickets/1') {
        handler.next(options);
        return;
      }
      attempts++;
      handler.resolve(Response(
        requestOptions: options,
        statusCode: attempts == 1 ? 503 : 200,
        data: attempts == 1
            ? null
            : {
                'ticket': {
                  'id': 1,
                  'ticket_no': 'SY2609140001',
                  'user_id': 10,
                  'type': 'bug',
                  'title': '已恢复的工单',
                  'description': '初始描述',
                  'status': 'investigating',
                  'status_note': '定位中',
                  'admin_viewed': true,
                  'user_unread_count': 0,
                  'created_at': '2026-09-14T08:00:00Z',
                  'updated_at': '2026-09-14T08:00:00Z',
                },
                'messages': <dynamic>[],
                'history': <dynamic>[],
              },
      ));
    }));
    final authProvider = _MockDetailAuthProvider(client: dio);
    final themeProvider = ThemeProvider(loadOnStart: false);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
      ],
      child: const MaterialApp(
        home: FeedbackDetailScreen(ticketId: 1, isAdmin: false),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('工单加载失败'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('初始描述'), findsOneWidget);
    expect(find.text('工单加载失败'), findsNothing);
  });

  testWidgets('图片选择器抛异常或取消选择时释放发送锁并保留输入草稿', (tester) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/feedback/tickets/1') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'ticket': {
                    'id': 1,
                    'ticket_no': 'SY2609140001',
                    'user_id': 10,
                    'type': 'bug',
                    'title': '测试工单异常恢复',
                    'description': '初始描述',
                    'status': 'investigating',
                    'status_note': '定位中',
                    'admin_viewed': true,
                    'user_unread_count': 0,
                    'created_at': DateTime(2026, 9, 14).toIso8601String(),
                    'updated_at': DateTime(2026, 9, 14).toIso8601String(),
                  },
                  'messages': <dynamic>[],
                  'history': <dynamic>[],
                },
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );

    final authProvider = _MockDetailAuthProvider(client: dio);
    final themeProvider = ThemeProvider(loadOnStart: false);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
        ],
        child: const MaterialApp(
          home: FeedbackDetailScreen(ticketId: 1, isAdmin: false),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 确认详情页加载成功
    expect(find.text('当前进度'), findsOneWidget);
    expect(find.text('初始描述'), findsOneWidget);

    // 找到输入框并输入草稿内容
    final textField = find.byType(TextField);
    expect(textField, findsOneWidget);
    await tester.enterText(textField, '未发送的草稿内容');
    await tester.pump();

    // 场景 1：图片选择器抛出 PlatformException
    fakePickerPlatform.throwOnPick = true;

    final imageBtn = find.byIcon(Icons.add_photo_alternate_outlined);
    expect(imageBtn, findsOneWidget);

    await tester.tap(imageBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 验证展示了错误 SnackBar 提示
    expect(find.textContaining('图片上传失败'), findsOneWidget);

    // 验证草稿内容未丢失
    expect(find.text('未发送的草稿内容'), findsOneWidget);

    // 验证发送状态已在 finally 中释放，输入框保持可编辑，图片按钮未被禁用
    final textFieldWidget = tester.widget<TextField>(textField);
    expect(textFieldWidget.readOnly, isFalse);

    // 场景 2：用户在系统相册中点击取消（返回 null）
    fakePickerPlatform.throwOnPick = false;
    fakePickerPlatform.pickedFile = null;

    await tester.tap(imageBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 状态依旧正常释放且草稿仍在
    final textFieldWidgetAfterCancel = tester.widget<TextField>(textField);
    expect(textFieldWidgetAfterCancel.readOnly, isFalse);
    expect(find.text('未发送的草稿内容'), findsOneWidget);
  });

  testWidgets('切号后同内容消息使用新幂等键，旧响应不再接管新会话', (tester) async {
    final dio = Dio();
    late final _MockDetailAuthProvider authProvider;
    RequestInterceptorHandler? firstSendHandler;
    RequestOptions? firstSendOptions;
    final idempotencyKeys = <String>[];
    final detailAccountIds = <int>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/feedback/tickets/1' &&
              options.method == 'GET') {
            final accountId = authProvider.currentUserId;
            detailAccountIds.add(accountId);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'ticket': {
                    'id': 1,
                    'ticket_no': 'SY2609140001',
                    'user_id': accountId,
                    'type': 'bug',
                    'title': '账号 $accountId 的工单',
                    'description': '初始描述',
                    'status': 'investigating',
                    'status_note': '定位中',
                    'admin_viewed': true,
                    'user_unread_count': 0,
                    'created_at': '2026-09-14T08:00:00Z',
                    'updated_at': '2026-09-14T08:00:00Z',
                  },
                  'messages': <dynamic>[],
                  'history': <dynamic>[],
                },
              ),
            );
            return;
          }
          if (options.path == '/feedback/tickets/1/messages') {
            idempotencyKeys.add(options.headers['Idempotency-Key'].toString());
            if (firstSendHandler == null) {
              firstSendHandler = handler;
              firstSendOptions = options;
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'ok': true},
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );

    authProvider = _MockDetailAuthProvider(client: dio);
    final themeProvider = ThemeProvider(loadOnStart: false);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
        ],
        child: const MaterialApp(
          home: FeedbackDetailScreen(ticketId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '同一条消息');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump(const Duration(milliseconds: 50));
    expect(idempotencyKeys, hasLength(1));

    authProvider.switchAccount(20);
    await tester.pumpAndSettle();
    expect(detailAccountIds.last, 20);

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    expect(idempotencyKeys, hasLength(2));
    expect(idempotencyKeys[1], isNot(idempotencyKeys[0]));

    firstSendHandler!.resolve(
      Response(
        requestOptions: firstSendOptions!,
        statusCode: 200,
        data: {'ok': true},
      ),
    );
    await tester.pumpAndSettle();
    expect(detailAccountIds.last, 20);
  });
}
