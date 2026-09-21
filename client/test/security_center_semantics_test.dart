import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/security_event.dart';
import 'package:shenliyuan/utils/security_event_presentation.dart';

SecurityEvent makeEvent({
  String eventType = 'login_failed',
  String severity = 'low',
  String status = 'active',
  String action = 'observed',
  bool actionable = true,
  String targetMasked = '26***27',
  int attemptCount = 1,
  int blockedCount = 0,
  int mailSentCount = 0,
  int passwordResetSuccessCount = 0,
  Map<String, dynamic> metadata = const {},
}) {
  return SecurityEvent(
    id: 1,
    eventType: eventType,
    severity: severity,
    status: status,
    route: '/api/login',
    method: 'POST',
    sourceFingerprint: '8a43···d3eb',
    sourceKey: '',
    installationSeen: false,
    actorUserId: null,
    targetType: 'account',
    targetMasked: targetMasked,
    requestIdSample: '',
    attemptCount: attemptCount,
    blockedCount: blockedCount,
    mailSentCount: mailSentCount,
    passwordResetSuccessCount: passwordResetSuccessCount,
    sourceAttributionValid: true,
    action: action,
    actionable: actionable,
    metadata: metadata,
    firstSeenAt: DateTime(2026, 9, 21, 7, 45),
    lastSeenAt: DateTime(2026, 9, 21, 7, 45),
    resolvedAt: null,
    resolutionNote: '',
  );
}

void main() {
  group('密码重置链路按阶段命名', () {
    // 三条事件曾经都叫「密码重置请求」，于是出现
    // 「请求 1 · 实际发信 0 · 成功改密 1」这种自相矛盾的卡片。
    test('申请阶段只显示申请数，不再显示发信 0', () {
      final event = makeEvent(
        eventType: 'password_reset_activity',
        action: 'request_accepted',
        attemptCount: 1,
      );
      expect(securityEventTitle(event), '密码重置验证码申请');
      expect(securityEventMetrics(event), ['验证码申请 1 次']);
    });

    test('发信阶段同时给出申请与发信两个数字', () {
      final event = makeEvent(
        eventType: 'password_reset_activity',
        action: 'mail_sent',
        attemptCount: 1,
        mailSentCount: 1,
      );
      expect(securityEventTitle(event), '密码重置验证码已发送');
      expect(securityEventMetrics(event), ['申请 1 次 · 实际发信 1 次']);
    });

    test('改密成功阶段显示成功改密', () {
      final event = makeEvent(
        eventType: 'password_reset_activity',
        action: 'password_reset_succeeded',
        passwordResetSuccessCount: 1,
        targetMasked: 'xi***@qq.com',
      );
      expect(securityEventTitle(event), '密码重置成功');
      expect(securityEventMetrics(event), ['成功改密 1 次']);
    });
  });

  group('登录事件分级', () {
    test('单次密码输错不叫登录暴力尝试', () {
      final event = makeEvent(
        eventType: 'login_failed',
        severity: 'low',
        attemptCount: 1,
      );
      expect(securityEventTitle(event), '登录失败观察');
      expect(securityEventMetrics(event), ['尝试 1 次']);
    });

    test('达到锁定阈值才升级为登录暴力尝试并体现拦截', () {
      final event = makeEvent(
        eventType: 'login_bruteforce',
        severity: 'medium',
        action: 'throttled',
        attemptCount: 3,
        blockedCount: 1,
      );
      expect(securityEventTitle(event), '登录暴力尝试');
      expect(securityEventMetrics(event), ['尝试 3 次 · 已拦截 1 次']);
    });

    test('多账号扫描显示涉及目标数而不是路由名', () {
      final event = makeEvent(
        eventType: 'login_password_spray',
        severity: 'high',
        action: 'throttled',
        targetMasked: '涉及 16 个账号（10 分钟）',
        attemptCount: 23,
        blockedCount: 23,
        metadata: const {'distinct_targets': 16, 'window': '10m'},
      );
      expect(securityEventTitle(event), '多账号登录扫描');
      expect(securityEventMetrics(event), ['10m内涉及 16 个目标 · 已拦截 23 次']);
    });
  });

  group('审计流水与待处置', () {
    test('正常验证码与正常改密标记为审计流水', () {
      expect(
        securityEventStatusLabel(makeEvent(
          eventType: 'verification_activity',
          action: 'request_accepted',
          actionable: false,
        )),
        '审计流水',
      );
      expect(
        securityEventStatusLabel(makeEvent(
          eventType: 'password_reset_activity',
          action: 'password_reset_succeeded',
          actionable: false,
        )),
        '审计流水',
      );
    });

    test('待处置事件按状态显示', () {
      expect(
        securityEventStatusLabel(makeEvent(status: 'active')),
        '待处置',
      );
      expect(
        securityEventStatusLabel(makeEvent(status: 'resolved')),
        '已处理',
      );
      expect(
        securityEventStatusLabel(makeEvent(status: 'false_positive')),
        '误报',
      );
    });
  });

  group('概览卡片口径', () {
    test('新后端使用高危待处理口径', () {
      final overview = SecurityOverview.fromJson({
        'range': '24h',
        'active_high_count': 2,
        'actionable_high_count': 1,
        'actionable_pending_count': 3,
        'total_events': 99,
        'blocked_requests': 129,
        'affected_targets': 99,
        'unique_sources': 60,
        'mail_sent_count': 38,
        'password_reset_success_count': 30,
      });
      expect(overview.pendingHighCount, 1);
    });

    test('旧后端回退到旧字段，不显示成 0', () {
      final overview = SecurityOverview.fromJson({
        'range': '24h',
        'active_high_count': 2,
        'total_events': 99,
      });
      expect(overview.pendingHighCount, 2);
    });
  });

  test('metadata_json 解析失败时按无元数据处理', () {
    final event = SecurityEvent.fromJson(<String, dynamic>{
      'id': 1,
      'event_type': 'login_password_spray',
      'metadata_json': '{not-json',
      'first_seen_at': '2026-09-21T07:45:00Z',
      'last_seen_at': '2026-09-21T07:45:00Z',
    });
    expect(event.distinctTargets, 0);
    expect(event.metadata, isEmpty);
  });

  // 顶部黑底是 Scaffold 与 AppBar 同时透明、而背景层只铺在 body 内导致的。
  // 这里沿用仓库既有的源码断言风格（见 security_regression_test.dart），
  // 防止后续改回透明 AppBar 再次出现深色底上深色字。
  test('安全中心 AppBar 使用不透明表面色', () {
    final source =
        File('lib/screens/admin_security_center_screen.dart').readAsStringSync();

    expect(source, isNot(contains('backgroundColor: Colors.transparent')));
    expect(source, contains('backgroundColor: surface'));
    expect(
      source,
      contains('foregroundColor: Theme.of(context).colorScheme.onSurface'),
    );
    expect(source, contains('surfaceTintColor: Colors.transparent'));
  });

  test('临时封禁默认最小作用域，全站封禁必须显式确认', () {
    final service =
        File('lib/services/admin_security_service.dart').readAsStringSync();
    expect(service, contains("String scope = 'route'"));
    expect(service, contains("'confirm_global': confirmGlobal"));

    final screen =
        File('lib/screens/admin_security_center_screen.dart').readAsStringSync();
    expect(screen, contains("var scope = routePrefix.isEmpty ? 'account' : 'route';"));
    expect(screen, contains("confirmGlobal: scope == 'all'"));
    expect(screen, contains("Text(scope == 'all' ? '确认全站封禁' : '确认封禁')"));
  });
}
