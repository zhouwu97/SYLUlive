import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/ai_assistant_provider.dart';
import 'package:shenliyuan/widgets/ai/ai_history_sheet.dart';
import 'package:shenliyuan/models/ai_conversation.dart';

class FakeAiAssistantProvider extends ChangeNotifier implements AiAssistantProvider {
  @override
  bool get loadingConversations => false;
  
  @override
  List<AiConversation> get conversations => [
    AiConversation(
      id: '1',
      title: '测试会话',
      createdAt: DateTime.now(),
      lastMessagePreview: '预览内容',
    )
  ];
  
  @override
  String? get conversationId => null;
  
  @override
  bool get isRunning => false;

  @override
  Future<void> startNewConversation() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('AiHistorySheet displays history list', (tester) async {
    final mockProvider = FakeAiAssistantProvider();
    
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<AiAssistantProvider>.value(
            value: mockProvider,
            child: const AiHistorySheet(),
          ),
        ),
      ),
    );

    expect(find.text('历史会话'), findsOneWidget);
    expect(find.text('测试会话'), findsOneWidget);
    expect(find.text('预览内容'), findsOneWidget);
  });
}
