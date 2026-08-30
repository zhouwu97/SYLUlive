import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/water_section.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/widgets/water_section/section_post_card.dart';

void main() {
  testWidgets('版块信息流长按正文复制完整内容', (tester) async {
    String? copiedText;
    var onTapCount = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    const section = WaterSection(id: 1, slug: 'general', title: '综合讨论');
    final post = Post(
      id: 1,
      title: '下载提示',
      content: 'https://example.com/download',
      boardId: 1,
      authorId: 1,
      createdAt: DateTime(2026, 8, 23),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AuthProvider(Dio(), loadStoredAuth: false),
        child: MaterialApp(
          home: Scaffold(
            body: SectionPostCard(
              post: post,
              section: section,
              accentColor: const Color(0xFF147C72),
              onTap: () => onTapCount++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('https://example.com/download'));
    await tester.pump();

    expect(copiedText, 'https://example.com/download');
    expect(find.text('帖子正文已复制'), findsOneWidget);
    expect(onTapCount, 0);
  });
}
