import '../models/security_event.dart';

/// 安全事件的展示语义。
///
/// 这些规则以前直接写在页面里，无法单测，于是「密码重置请求」把申请验证码、实际发信、
/// 完成改密三个阶段混成同一个标题，卡片又对所有类型固定打印「实际发信 0 次 · 成功改密
/// 0 次」，看起来像自相矛盾的数据。抽成纯函数后：标题由 event_type + action 共同决定，
/// 指标行只包含与该阶段相关的字段。

/// 事件标题。action 参与判定的原因是密码重置/验证码链路的三条事件共用同一个 event_type，
/// 只有 action 能区分「已申请」「已发信」「已改密」。
String securityEventTitle(SecurityEvent event) => switch (event.eventType) {
      'password_reset_activity' => switch (event.action) {
          'mail_sent' => '密码重置验证码已发送',
          'password_reset_succeeded' => '密码重置成功',
          'request_accepted' => '密码重置验证码申请',
          _ => '密码重置活动',
        },
      'verification_activity' => switch (event.action) {
          'mail_sent' => '验证码已发送',
          'request_accepted' => '验证码申请',
          _ => '验证码活动',
        },
      'verification_mail_delivery_failed' => '验证码邮件发送失败',
      'password_reset_spray' => '密码重置喷洒',
      'verification_spray' => '验证码喷洒',
      'verification_source_rate' => '验证码来源限流',
      'verification_cooldown' => '验证码冷却拦截',
      'email_target_flood' => '验证码目标轰炸',
      'verification_code_bruteforce' => '验证码暴力尝试',
      'login_password_spray' => '多账号登录扫描',
      'login_failed' => '登录失败观察',
      'login_bruteforce' => '登录暴力尝试',
      'refresh_token_reused' => 'Refresh Token Reuse',
      'suspicious_password_reset_succeeded' => '可疑密码重置成功',
      'content_post_flood' => '发帖刷屏',
      'content_reply_flood' => '评论刷屏',
      'private_message_flood' => '私信刷屏',
      'feedback_ticket_flood' => '反馈工单刷量',
      'security_blocked_request' => '来源封禁拦截',
      'search_abuse' => '搜索扫描',
      _ => event.eventType,
    };

/// 与事件类型和阶段相关的指标行。
///
/// 不会再出现「密码重置验证码申请」卡片上显示「实际发信 0 次」这种情况：
/// 申请阶段根本不该展示发信数，发信数只属于 mail_sent 阶段的事件。
List<String> securityEventMetrics(SecurityEvent event) {
  final parts = <String>[];
  if (isSprayEvent(event.eventType)) {
    final targets = event.distinctTargets;
    parts.add(targets > 0
        ? '${sprayWindowLabel(event)}内涉及 $targets 个目标'
        : '请求 ${event.attemptCount} 次');
    if (event.blockedCount > 0) parts.add('已拦截 ${event.blockedCount} 次');
    return [parts.join(' · ')];
  }

  switch (event.eventType) {
    case 'password_reset_activity':
    case 'verification_activity':
      switch (event.action) {
        case 'mail_sent':
          parts.add('申请 ${event.attemptCount} 次');
          parts.add('实际发信 ${event.mailSentCount} 次');
          break;
        case 'password_reset_succeeded':
          parts.add('成功改密 ${event.passwordResetSuccessCount} 次');
          break;
        default:
          parts.add('验证码申请 ${event.attemptCount} 次');
          if (event.mailSentCount > 0) {
            parts.add('实际发信 ${event.mailSentCount} 次');
          }
      }
      break;
    default:
      parts.add('尝试 ${event.attemptCount} 次');
      if (event.blockedCount > 0) parts.add('已拦截 ${event.blockedCount} 次');
      if (event.mailSentCount > 0) parts.add('实际发信 ${event.mailSentCount} 次');
      if (event.passwordResetSuccessCount > 0) {
        parts.add('成功改密 ${event.passwordResetSuccessCount} 次');
      }
  }
  if (event.blockedCount > 0 && !parts.any((part) => part.contains('已拦截'))) {
    parts.add('已拦截 ${event.blockedCount} 次');
  }
  return [parts.join(' · ')];
}

/// 处置阶段说明。同一个 action 在不同事件类型下含义不同，必须按类型解释。
String securityEventActionLabel(SecurityEvent event) => switch (event.action) {
      'observed' => '仅观察，未拦截',
      'throttled' || 'rate_limited' => '已限流',
      'blocked' => '已拦截',
      'mail_sent' => '验证码已投递',
      'mail_failed' => '邮件投递失败',
      'request_accepted' => '已受理',
      'password_reset_succeeded' => '已完成改密',
      _ => event.action.isEmpty ? '未记录' : event.action,
    };

/// 列表右侧的状态说明。
///
/// 审计流水使用独立文案，不再和「处理中」混在一起——正常验证码、正常改密、
/// 单次密码输错本来就不需要任何人处理。
String securityEventStatusLabel(SecurityEvent event) {
  if (!event.actionable) return '审计流水';
  return switch (event.status) {
    'resolved' => '已处理',
    'false_positive' => '误报',
    'active' => '待处置',
    _ => event.status,
  };
}

bool isSprayEvent(String eventType) => switch (eventType) {
      'login_password_spray' ||
      'password_reset_spray' ||
      'verification_spray' =>
        true,
      _ => false,
    };

String sprayWindowLabel(SecurityEvent event) {
  final window = event.metadata['window']?.toString() ?? '';
  return window.isEmpty ? '同一窗口' : window;
}

String securitySeverityLabel(String value) => switch (value) {
      'critical' => '严重',
      'high' => '高危',
      'medium' => '中危',
      'low' => '提示',
      _ => '信息',
    };

/// 临时封禁范围的说明文字。
///
/// 路径清单取自服务端 security/overview 的 security_block_scopes：它和真正写进封禁表、
/// 被中间件命中的是同一张路由登记表。客户端不再自己抄一份路径——「界面说封住了账号相关
/// 入口、实际清单更窄」这个预期差，正是两份清单各写各的产物。
/// 旧服务端没有该字段时只解释范围语义，不冒充具体路径。
String securityBlockScopeDescription(
    Map<String, dynamic>? catalog, String scope) {
  final scopes = catalog?['scopes'];
  final entry = scopes is Map ? scopes[scope] : null;
  final parts = <String>[];
  final description = entry is Map ? entry['description']?.toString() ?? '' : '';
  parts.add(description.isNotEmpty
      ? description
      : switch (scope) {
          'account' => '登录注册、验证码、改密与邮箱换绑、会话刷新等账号凭据入口',
          'all' => '登记表内的全部高风险接口',
          _ => '仅当前这一条接口前缀',
        });
  final prefixes = entry is Map ? entry['prefixes'] : null;
  if (prefixes is List && prefixes.isNotEmpty) {
    parts.add('实际路径：${prefixes.map((e) => e.toString()).join(' · ')}');
  }
  // 方法策略也由服务端下发：内容组只认写方法，界面不能自己猜「封了什么」。
  final methodPolicy = catalog?['method_policy'];
  final methodNote =
      methodPolicy is Map ? methodPolicy['note']?.toString() ?? '' : '';
  if (methodNote.isNotEmpty) {
    parts.add(methodNote);
  }
  if (scope == 'account' && catalog?['account_excludes'] is List) {
    final excluded =
        (catalog!['account_excludes'] as List).map((e) => e.toString()).join(' · ');
    if (excluded.isNotEmpty) {
      parts.add('不包含：$excluded');
    }
  }
  return parts.join('；');
}
