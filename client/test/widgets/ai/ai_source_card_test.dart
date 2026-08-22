import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';
import 'package:shenliyuan/models/ai_source.dart';
import 'package:shenliyuan/widgets/ai/ai_message_card.dart';
import 'package:shenliyuan/widgets/ai/ai_source_card.dart';

void main() {
  testWidgets('政策消息不展示裸 chunk ID，并展示聚合引用位置', (tester) async {
    const title = '沈阳理工大学本科课程考核与成绩管理办法（完整正式版本）';
    final message = AiChatMessage(
      id: 'message-1',
      requestId: 'request-1',
      role: AiMessageRole.assistant,
      content: '请按规定办理。[chunk:18]',
      status: AiMessageStatus.completed,
      createdAt: DateTime.utc(2026, 7, 28),
      sources: [
        AiSource(
          type: AiSourceType.policy,
          chunkId: 18,
          documentId: 3,
          title: title,
          publisher: '学生处',
          status: 'published',
          effectiveFrom: DateTime.utc(2025, 9, 1),
          effectiveTo: DateTime.utc(2027, 8, 31),
          citationNumbers: [1, 2],
          locators: ['第十条', '第十一条'],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AiMessageCard(message: message))),
    );

    expect(find.textContaining('chunk:18'), findsNothing);
    expect(find.textContaining('[1]'), findsAtLeastNWidgets(1));
    expect(find.textContaining('[1][2]'), findsOneWidget);
    expect(tester.widget<Text>(find.text(title).first).maxLines, 1);

    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(title).last).maxLines, isNull);
    expect(find.text('发布部门'), findsOneWidget);
    expect(find.text('学生处'), findsOneWidget);
    expect(find.text('文档状态'), findsOneWidget);
    expect(find.text('已发布'), findsOneWidget);
    expect(find.text('生效时间'), findsOneWidget);
    expect(find.text('2025-09-01 至 2027-08-31'), findsOneWidget);
    expect(find.text('条款位置'), findsOneWidget);
    expect(find.textContaining('第十条 · 第十一条'), findsOneWidget);
  });

  testWidgets('竞赛目录来源展示公开事实且不请求政策正文', (tester) async {
    var contentRequests = 0;
    const source = AiSource(
      type: AiSourceType.competitionCatalog,
      chunkId: 99,
      title: '全国大学生程序设计竞赛',
      competitionId: 'COMP-2026-001',
      datasetVersion: 'catalog-2026-07',
      schoolRecognition: 'A',
      competitionRating: 'S',
      evidenceSubgrade: 'A1',
      aiMode: 'candidate_explanation',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiSourceCard(
            source: source,
            loadContent: (_) async {
              contentRequests++;
              return const AiSourceContent(
                chunkId: 99,
                documentId: 1,
                title: '不应读取',
                content: '不应展示',
              );
            },
          ),
        ),
      ),
    );

    expect(find.textContaining('竞赛目录'), findsOneWidget);
    await tester.tap(find.text(source.title));
    await tester.pumpAndSettle();

    expect(find.text('目录版本'), findsOneWidget);
    expect(find.text('catalog-2026-07'), findsOneWidget);
    expect(find.text('赛事编号'), findsOneWidget);
    expect(find.text('COMP-2026-001'), findsOneWidget);
    expect(find.text('学校认定'), findsOneWidget);
    expect(find.text('赛事价值'), findsOneWidget);
    expect(find.text('证据等级'), findsOneWidget);
    expect(find.text('候选解释'), findsOneWidget);
    expect(find.textContaining('不代表获奖概率'), findsOneWidget);
    expect(contentRequests, 0);
  });
}
