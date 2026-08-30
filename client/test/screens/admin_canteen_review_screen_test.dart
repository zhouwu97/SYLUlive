import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/admin_canteen_review_screen.dart';
import 'package:shenliyuan/widgets/canteen/canteen_pending_card.dart';

class _RouteJsonAdapter implements HttpClientAdapter {
  final Map<String, Object> responses;

  const _RouteJsonAdapter(this.responses);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final payload = responses[options.uri.path];
    if (payload == null) {
      return _notFound();
    }
    final resolved = payload is Object? Function(RequestOptions)
        ? payload(options)
        : payload;
    if (resolved == null) {
      return _notFound();
    }
    return ResponseBody.fromString(
      jsonEncode(resolved),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  ResponseBody _notFound() {
    return ResponseBody.fromString(
      jsonEncode({'error': 'not found'}),
      404,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

Widget _buildScreenApp({
  required Map<String, Object> responses,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
  dio.httpClientAdapter = _RouteJsonAdapter(responses);

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(
        value: AuthProvider(dio, loadStoredAuth: false),
      ),
      ChangeNotifierProvider<CanteenProvider>(
        create: (_) => CanteenProvider(dio),
      ),
    ],
    child: const MaterialApp(
      home: AdminCanteenReviewScreen(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdminCanteenReviewScreen 审核流程集成测试', () {
    testWidgets('待审核列表展示审核卡片并支持审批通过', (tester) async {
      var approved = false;
      final pending = [
        {
          'id': 11,
          'name': '二食堂新档口·川味麻辣香锅',
          'creator_name': '张同学',
          'created_at': '2026-08-28T10:00:00Z',
          'image': '',
        },
      ];

      await tester.pumpWidget(
        _buildScreenApp(
          responses: {
            '/canteens/pending': {'items': pending},
            '/canteens/11/approve': (RequestOptions opt) {
              approved = true;
              return {'message': '审核已通过'};
            },
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('食堂审核'), findsOneWidget);
      expect(find.byType(CanteenPendingCard), findsOneWidget);
      expect(find.text('二食堂新档口·川味麻辣香锅'), findsOneWidget);
      expect(find.textContaining('张同学'), findsOneWidget);

      // 点击“审核通过”
      final approveBtn = find.widgetWithText(FilledButton, '审核通过');
      expect(approveBtn, findsOneWidget);
      await tester.tap(approveBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(approved, isTrue);
      // 卡片通过后被移除
      expect(find.byType(CanteenPendingCard), findsNothing);
      expect(find.text('暂无待审核食堂'), findsOneWidget);
    });

    testWidgets('驳回流程弹出原因对话框并在确认后移除卡片', (tester) async {
      var rejected = false;
      String? rejectedReason;

      final pending = [
        {
          'id': 22,
          'name': '重复提交的奶茶店',
          'creator_name': '李同学',
          'created_at': '2026-08-28T11:00:00Z',
          'image': '',
        },
      ];

      await tester.pumpWidget(
        _buildScreenApp(
          responses: {
            '/canteens/pending': {'items': pending},
            '/canteens/22/pending': (RequestOptions opt) {
              rejected = true;
              rejectedReason = opt.data is Map ? opt.data['reason']?.toString() : '';
              return {'message': '已驳回'};
            },
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 点击“驳回”
      final rejectBtn = find.widgetWithText(OutlinedButton, '驳回');
      expect(rejectBtn, findsOneWidget);
      await tester.tap(rejectBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 验证弹出驳回对话框
      expect(find.text('驳回「重复提交的奶茶店」？'), findsOneWidget);
      expect(find.text('确认驳回'), findsOneWidget);

      // 输入驳回原因
      await tester.enterText(find.byType(TextField), '档口名称与已有商家重复');
      await tester.tap(find.text('确认驳回'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(rejected, isTrue);
      expect(rejectedReason, equals('档口名称与已有商家重复'));
      expect(find.byType(CanteenPendingCard), findsNothing);
    });

    testWidgets('列表为空时展示优雅空态', (tester) async {
      await tester.pumpWidget(
        _buildScreenApp(
          responses: {
            '/canteens/pending': {'items': <Object>[]},
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('暂无待审核食堂'), findsOneWidget);
      expect(find.text('新的商家提交会出现在这里'), findsOneWidget);
    });
  });
}
