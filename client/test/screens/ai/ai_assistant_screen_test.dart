import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import 'package:shenliyuan/screens/ai/ai_assistant_screen.dart';
import 'package:shenliyuan/services/ai_assistant_service.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
import 'package:shenliyuan/models/user.dart';

class FakeAiAssistantService implements AiAssistantService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  @override
  User? get user => null;
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
          ),
        ),
      ),
    );

    // Initial load expects "校园问答" and an input field
    expect(find.text('校园问答'), findsWidgets);
    expect(find.text('个人助手'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
