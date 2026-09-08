import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/presentation/academic_restore_status.dart';
import 'package:shenliyuan/screens/course_schedule_screen.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';

void main() {
  test('身份和缓存已就绪时后台读取不遮挡已有课程', () {
    expect(resolveScheduleViewState(
      eduStatusLoaded: true, eduBound: true,
      sessionPhase: ScheduleSessionPhase.ready, isLoading: true,
      isInitializing: false, hasCourses: true, hasSemesterStart: true,
    ), ScheduleViewState.ready);
  });
  testWidgets('恢复等待超时后提供重试，重试期间禁用重复提交', (tester) async {
    final retry = Completer<void>();
    var requests = 0;
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: AcademicRestoreStatus(
      onRetry: () {
        requests++;
        return retry.future;
      },
    ))));
    expect(find.text('正在恢复本机课表状态'), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
    expect(find.text('课表恢复暂未完成'), findsOneWidget);
    await tester.tap(find.text('重试恢复'));
    await tester.pump();
    expect(requests, 1);
    expect(find.text('正在恢复本机课表状态'), findsOneWidget);
    retry.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('身份读取明确失败立即显示错误，不伪装为空课表', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AcademicRestoreStatus(
      error: '确认教务身份超时，请检查网络后重试',
      onRetry: () async {},
    ))));
    expect(find.text('课表恢复暂未完成'), findsOneWidget);
    expect(find.text('重试恢复'), findsOneWidget);
    expect(find.text('正在恢复本机课表状态'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('重试挂起也在限时后结束忙碌状态', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AcademicRestoreStatus(
      error: '恢复失败',
      onRetry: () => Completer<void>().future,
    ))));
    await tester.tap(find.text('重试恢复'));
    await tester.pump(const Duration(seconds: 16));
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNotNull);
    expect(find.text('课表恢复暂未完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
