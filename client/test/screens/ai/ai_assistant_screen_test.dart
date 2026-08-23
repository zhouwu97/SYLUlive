import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import 'package:shenliyuan/screens/ai/ai_assistant_screen.dart';
import 'package:shenliyuan/features/ai_runtime/personal_session/personal_conversation_store.dart';
import 'package:shenliyuan/services/ai_assistant_service.dart';
import 'package:shenliyuan/platform/contracts/blob_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';
import 'package:shenliyuan/models/user.dart';

class FakeAiAssistantService implements AiAssistantService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  FakeAuthProvider([this.currentUser]);

  User? currentUser;
  int _accountSessionEpoch = 0;

  @override
  User? get user => currentUser;

  @override
  bool get isLoggedIn => currentUser != null;

  @override
  int get accountSessionEpoch => _accountSessionEpoch;

  void setUser(User? value) {
    if (currentUser?.id != value?.id) {
      _accountSessionEpoch++;
    }
    currentUser = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeEduProvider extends ChangeNotifier implements EduProvider {
  @override
  String get studentId => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('AiAssistantScreen builds successfully', (tester) async {
    final mockService = FakeAiAssistantService();
    final mockAuth = FakeAuthProvider();
    final mockEdu = FakeEduProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: mockAuth),
          ChangeNotifierProvider<EduProvider>.value(value: mockEdu),
        ],
        child: MaterialApp(
          home: AiAssistantScreen(
            service: mockService,
            dio: Dio(),
            capabilities: AiCapabilities.fromJson(const {}),
            initialPrompt: '分析我的学业情况',
          ),
        ),
      ),
    );

    // Initial load expects "校园 Agent" and an input field
    expect(find.text('校园 Agent'), findsWidgets);
    expect(find.text('个人助手'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '分析我的学业情况',
    );

    await tester.tap(find.text('个人助手'));
    await tester.pumpAndSettle();
    expect(find.text('竞赛搜索'), findsOneWidget);
    expect(find.text('竞赛建议'), findsNothing);
    expect(find.text('毕业清单'), findsNothing);
  });

  testWidgets('AI 页面暗色主题下控件保持可渲染', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(
            value: FakeAuthProvider(),
          ),
          ChangeNotifierProvider<EduProvider>.value(
            value: FakeEduProvider(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: AiAssistantScreen(
            service: FakeAiAssistantService(),
            dio: Dio(),
            capabilities: AiCapabilities.fromJson(const {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('校园 Agent'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('Hy3 能力决定三个业务入口是否可见', (tester) async {
    Widget buildScreen(Map<String, dynamic> features) => MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(
              value: FakeAuthProvider(),
            ),
            ChangeNotifierProvider<EduProvider>.value(
              value: FakeEduProvider(),
            ),
          ],
          child: MaterialApp(
            home: AiAssistantScreen(
              service: FakeAiAssistantService(),
              dio: Dio(),
              capabilities: AiCapabilities.fromJson({
                'enabled': true,
                'access_allowed': true,
                'chat_enabled': true,
                'features': features,
              }),
            ),
          ),
        );

    await tester.pumpWidget(
      buildScreen(const {
        'hy3_competition_compare': true,
        'hy3_academic_analysis': true,
        'hy3_week_plan': true,
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text('近期竞赛'), findsOneWidget);
    expect(find.text('学业风险'), findsOneWidget);
    expect(find.text('本周空闲'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(buildScreen(const {}));
    await tester.pumpAndSettle();

    expect(find.text('近期竞赛'), findsOneWidget);
    expect(find.text('学业风险'), findsOneWidget);
    expect(find.text('本周空闲'), findsOneWidget);
  });

  testWidgets('个人历史在页面重建后恢复且切换账号立即隔离', (tester) async {
    final secure = _FakeBlobStore();
    PersonalConversationStore storeFor(String accountKey) =>
        PersonalConversationStore(accountKey: accountKey, blobStore: secure);
    await storeFor('1::').replace(<PersonalConversationEntry>[
      PersonalConversationEntry(
        message: AiChatMessage(
          id: 'assistant-history',
          requestId: 'history',
          role: AiMessageRole.assistant,
          content: 'A 账号的个人历史',
          status: AiMessageStatus.completed,
          createdAt: DateTime.utc(2026, 7, 21),
        ),
      ),
    ]);
    final auth = FakeAuthProvider(_user(1));
    final edu = FakeEduProvider();

    Future<void> pumpScreen() => tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthProvider>.value(value: auth),
              ChangeNotifierProvider<EduProvider>.value(value: edu),
            ],
            child: MaterialApp(
              home: AiAssistantScreen(
                service: FakeAiAssistantService(),
                dio: Dio(),
                capabilities: AiCapabilities.fromJson(const {}),
                personalConversationStoreFactory: storeFor,
              ),
            ),
          ),
        );

    await pumpScreen();
    await tester.pumpAndSettle();
    await tester.tap(find.text('个人助手'));
    await tester.pumpAndSettle();
    expect(find.text('A 账号的个人历史'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpScreen();
    await tester.pumpAndSettle();
    await tester.tap(find.text('个人助手'));
    await tester.pumpAndSettle();
    expect(find.text('A 账号的个人历史'), findsOneWidget);

    auth.setUser(_user(2));
    await tester.pumpAndSettle();
    expect(find.text('A 账号的个人历史'), findsNothing);
  });

  testWidgets('公共与个人模式使用独立输入上限并随模式立即更新', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(
            value: FakeAuthProvider(),
          ),
          ChangeNotifierProvider<EduProvider>.value(
            value: FakeEduProvider(),
          ),
        ],
        child: MaterialApp(
          home: AiAssistantScreen(
            service: FakeAiAssistantService(),
            dio: Dio(),
            capabilities: AiCapabilities.fromJson(const {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 公共模式输入为空时隐藏计数器。
    expect(find.text('0/500'), findsNothing);

    await tester.tap(find.text('个人助手'));
    await tester.pumpAndSettle();
    // 个人模式输入为空时隐藏计数器。
    expect(find.text('0/8000'), findsNothing);

    await tester.enterText(find.byType(TextField), 'a');
    await tester.pumpAndSettle();
    expect(find.text('1/8000'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '二十一字符以上的个人助手问题仍然应该允许发送');
    await tester.pump();
    final personalSend = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
    );
    expect(personalSend.onPressed, isNotNull);

    await tester.enterText(
      find.byType(TextField),
      List<String>.filled(8001, 'x').join(),
    );
    await tester.pump();
    expect(find.text('8001/8000'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('校园 Agent'));
    await tester.pump();
    expect(find.text('8001/500'), findsOneWidget);
  });
}

User _user(int id) => User(
      id: id,
      studentId: 'student-$id',
      nickname: 'user-$id',
      createdAt: DateTime.utc(2026, 7, 21),
    );

class _FakeBlobStore implements AppBlobStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
