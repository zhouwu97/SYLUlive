import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/ai/ai_agent_permission_sheet.dart';

class _PermissionModeErrorAdapter implements HttpClientAdapter {
  _PermissionModeErrorAdapter(this.statusCode);

  final int statusCode;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      jsonEncode({'error': 'authentication_required'}),
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

void main() {
  testWidgets('权限读取失败时展示原因而不是空白弹层', (tester) async {
    final dio = Dio()..httpClientAdapter = _PermissionModeErrorAdapter(401);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAgentPermissionSheet(dio: dio),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂时读取不到 Agent 权限'), findsOneWidget);
    expect(find.text('请先登录后再设置 Agent 权限'), findsOneWidget);
    expect(find.text('重新加载权限'), findsOneWidget);
  });
}
