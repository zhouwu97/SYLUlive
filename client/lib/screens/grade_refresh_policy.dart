/// 成绩页刷新权限与减少保护的纯决策逻辑（计划 8.2 / 8.3 / 8.5）。
///
/// 为什么单独抽出来：这三项权限**互相独立**，混在同一个 widget 的可变字段里
/// 很容易退化成互相冲突的 bool（例如 silent=false 顺带授予了「覆盖减少」的权限）。
/// 抽成纯函数后可以脱离 widget 直接验证决策表与减少确认的作用域语义。
///
/// 三项权限分别是：
/// 1. 是否突破缓存新鲜期 —— 由 [decideGradeLoad] 决定发不发网络请求；
/// 2. 是否允许打断用户重新输入凭据 —— 仍由页面既有的会话恢复流程控制，不在这里；
/// 3. 是否允许减少后的结果覆盖可信基线 —— 由 [allowReducedGradeOverwrite] 与
///    [GradeReductionConfirmation] 共同决定。
library;

/// 成绩刷新的触发来源。计划 8.2 要求区分 initial / automatic / resume / manual。
enum GradeRefreshOrigin {
  /// 首次进入页面。
  initial,

  /// 定时或条件触发的自动刷新。
  automatic,

  /// 前台恢复。
  resume,

  /// 用户明确下拉刷新 / 点重试。
  manual,
}

/// 单轮成绩加载的决策。
enum GradeLoadDecision {
  /// 只展示缓存，不发起网络请求。
  cacheOnly,

  /// 先展示缓存，同时在后台刷新一次。
  cacheThenRefresh,

  /// 没有可信缓存：进入完整加载状态。
  fullLoad,
}

/// 缓存是否仍在新鲜期内。
bool gradeCacheIsFresh({
  required DateTime updatedAt,
  required DateTime now,
  required Duration freshFor,
}) {
  return now.difference(updatedAt) <= freshFor;
}

/// 是否处于失败退避期。
bool gradeInFailureBackoff({
  required DateTime? lastFailureAt,
  required DateTime now,
  required Duration backoff,
}) {
  return lastFailureAt != null && now.difference(lastFailureAt) < backoff;
}

/// 计划 8.3 决策表的唯一实现。
///
/// 关键点：**新鲜期与失败退避期都只约束「自动」触发**。
/// 处于失败退避期时，自动 / 前台恢复不得请求，但缓存新鲜时同样不得请求；
/// 只有用户明确刷新（[userInitiated]）才允许绕过时间维度的退避，
/// 仍然继续遵守 single-flight 与身份检查（那两项不在这里决定）。
GradeLoadDecision decideGradeLoad({
  required bool hasCredibleCache,
  required bool isFresh,
  required bool inFailureBackoff,
  required bool userInitiated,
}) {
  if (!hasCredibleCache) return GradeLoadDecision.fullLoad;
  if (!userInitiated && (isFresh || inFailureBackoff)) {
    return GradeLoadDecision.cacheOnly;
  }
  return GradeLoadDecision.cacheThenRefresh;
}

/// 是否允许「减少后的结果」覆盖可信基线。
///
/// 计划 8.2 明确：该权限**不得**由 `silent == false` 或 `forceRefresh == true`
/// 顺带授予，必须另有用户确认。因此自动 / 前台恢复（[silent]）永远返回 false。
bool allowReducedGradeOverwrite({
  required bool silent,
  required bool userConfirmedReduction,
}) {
  return !silent && userConfirmedReduction;
}

/// 「成绩减少」确认的作用域与一次性消费语义（计划 8.5）。
///
/// - 首次遇到减少只调用 [warn] 记录提示，不授予覆盖权限；
/// - 用户在提示之后**再次**明确刷新时调用 [consume] 取回确认；
/// - 确认只对同一账号 / 教务身份 / 学期（[scope]）有效：期间切号或切学期，
///   scope 不同则 [consume] 失败，旧确认不会作用到新上下文。
///
/// 确认还必须绑定**具体候选结果**（[signature]）：只按作用域放行是不够的，
/// 「20 门 -> 19 门」的提示不能被复用成「19 门 -> 0 门」的覆盖授权——
/// 重新请求后结果再次变化时，用户并没有对新的结果点过头。因此 [warn] 记录
/// 提醒时那份结果的指纹，[consume] 把它交回调用方，由调用方与本次实际返回的
/// 结果指纹比较，只有完全一致才承认这是一次有效确认。
class GradeReductionConfirmation {
  String? _pendingScope;
  String? _pendingSignature;

  /// 记录「已就本次减少给出过提示」，等待用户再次确认。
  ///
  /// [signature] 是本次减少结果（将被写入的候选课程集合）的稳定指纹。
  void warn(String scope, String signature) {
    _pendingScope = scope;
    _pendingSignature = signature;
  }

  /// 尝试把上一次提示消费成一次覆盖确认。
  ///
  /// 返回 [warn] 时记录的候选结果指纹；作用域不匹配或没有待确认提示时返回 null。
  /// 无论返回什么，待确认状态都会被清空（一次性消费）。
  String? consume(String scope) {
    if (_pendingScope == null || _pendingScope != scope) return null;
    final signature = _pendingSignature;
    _pendingScope = null;
    _pendingSignature = null;
    return signature;
  }

  /// 上下文变化（切号 / 切学期）时废弃未消费的确认。
  void reset() {
    _pendingScope = null;
    _pendingSignature = null;
  }

  /// 是否存在待用户确认的减少提示（仅用于测试与诊断）。
  bool get hasPendingWarning => _pendingScope != null;
}
