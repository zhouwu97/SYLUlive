import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/screens/poll/poll_composer_screen.dart';

class _Service extends PollService {
  _Service() : super(Dio());
}

void main() {
  testWidgets('编辑器默认保留两个选项并显示必要字段', (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => PollProvider(_Service()),
        child: const MaterialApp(home: PollComposerScreen())));
    expect(find.text('投票标题'), findsOneWidget);
    expect(find.text('投票选项'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('投票设置'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('投票设置'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('实时公开结果'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('实时公开结果'), findsOneWidget);
    expect(find.text('结束后公开结果'), findsOneWidget);
    expect(find.text('仅作者查看'), findsOneWidget);
  });
}
