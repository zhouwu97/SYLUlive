import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/app_feedback.dart';
import 'package:shenliyuan/utils/app_navigator.dart';
import 'package:shenliyuan/widgets/group_chat_dialog.dart';

void main() {
  test('handles Dio receive timeout as a service timeout', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/test'),
      type: DioExceptionType.receiveTimeout,
    );

    final message = AppFeedback.dioErrorMessage(
      error,
      serviceName: 'Edu API',
      fallback: 'fallback',
    );

    expect(message, contains('Edu API'));
    expect(message, isNot('fallback'));
  });

  test('handles Dio transform timeout as a service processing timeout', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/test'),
      type: DioExceptionType.transformTimeout,
    );

    final message = AppFeedback.dioErrorMessage(
      error,
      serviceName: 'Edu API',
      fallback: 'fallback',
    );

    expect(message, contains('Edu API'));
    expect(message, contains('响应处理超时'));
    expect(message, isNot('fallback'));
  });

  testWidgets('feedback reserves the bottom safe-area inset', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: MediaQuery(
          data: const MediaQueryData(
            viewPadding: EdgeInsets.only(bottom: 34),
          ),
          child: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => AppFeedback.info('已复制', context: context),
                child: const Text('显示提示'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示提示'));
    await tester.pump();

    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(
      snackBar.margin,
      const EdgeInsets.fromLTRB(16, 0, 16, 50),
    );
  });

  testWidgets('copying the group number keeps feedback above the QR dialog',
      (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showGroupChatDialog(context),
              child: const Text('打开群聊弹窗'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开群聊弹窗'));
    await tester.pumpAndSettle();
    expect(find.text('复制群号'), findsOneWidget);

    await tester.tap(find.text('复制群号'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('QQ群号已复制到剪贴板'), findsOneWidget);
  });

  testWidgets('群号复制反馈支持深色模式和较大字体', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showGroupChatDialog(context),
                  child: const Text('打开群聊弹窗'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开群聊弹窗'));
    await tester.pump();
    await tester.tap(find.text('复制群号'));
    await tester.pump();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('QQ群号已复制到剪贴板'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
