/// 服务端 403 的统一恢复分类。
///
/// 403 不代表登录失效：协议限制进入同意页面，管理员权限变化只收敛
/// 管理员 UI。具体请求是否允许在确认后重放，仍由业务调用方显式决定。
enum ForbiddenRecoveryKind {
  communityRulesRequired,
  legalConsentRequired,
  legalConsentWithdrawn,
  adminRequired,
  superAdminRequired,
}

class ForbiddenRecoveryRoute {
  const ForbiddenRecoveryRoute({required this.kind, required this.code});

  final ForbiddenRecoveryKind kind;
  final String code;

  bool get requiresConsent =>
      kind == ForbiddenRecoveryKind.communityRulesRequired ||
      kind == ForbiddenRecoveryKind.legalConsentRequired ||
      kind == ForbiddenRecoveryKind.legalConsentWithdrawn;

  bool get requiresAdminUiShutdown =>
      kind == ForbiddenRecoveryKind.adminRequired ||
      kind == ForbiddenRecoveryKind.superAdminRequired;

  bool get consentIsRequired =>
      kind == ForbiddenRecoveryKind.communityRulesRequired ||
      kind == ForbiddenRecoveryKind.legalConsentRequired;
}

class ForbiddenRecoveryRouter {
  const ForbiddenRecoveryRouter._();

  /// 403 恢复后是否允许业务层重新发起原请求。
  ///
  /// 读取请求可以安全重试；写请求即使用户已经确认权限，也不能隐式重放，
  /// 只有调用方明确携带稳定 Idempotency-Key 时才允许由业务层决定重试。
  static bool canReplay({
    required String method,
    required bool hasIdempotencyKey,
  }) {
    final normalizedMethod = method.trim().toUpperCase();
    if (normalizedMethod == 'GET' || normalizedMethod == 'HEAD') return true;
    if (normalizedMethod == 'POST' ||
        normalizedMethod == 'PUT' ||
        normalizedMethod == 'PATCH' ||
        normalizedMethod == 'DELETE') {
      return hasIdempotencyKey;
    }
    return false;
  }

  static ForbiddenRecoveryRoute? resolve(Object? rawCode) {
    final code = rawCode?.toString().trim();
    if (code == null || code.isEmpty) return null;
    final kind = switch (code) {
      'community_rules_required' =>
        ForbiddenRecoveryKind.communityRulesRequired,
      'legal_consent_required' => ForbiddenRecoveryKind.legalConsentRequired,
      'legal_consent_withdrawn' => ForbiddenRecoveryKind.legalConsentWithdrawn,
      'admin_required' => ForbiddenRecoveryKind.adminRequired,
      'super_admin_required' => ForbiddenRecoveryKind.superAdminRequired,
      _ => null,
    };
    return kind == null ? null : ForbiddenRecoveryRoute(kind: kind, code: code);
  }
}
