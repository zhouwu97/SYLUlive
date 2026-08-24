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
