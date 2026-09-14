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

  @override
  User? get user => User(
        id: 10,
        studentId: '2026001',
        nickname: '学生小明',
        createdAt: DateTime(2026, 9, 14),
      );

  @override
  bool get isLoggedIn => true;

  @override
  int get sessionGeneration => 1;

  @override
  Dio get dio => client;

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
}
