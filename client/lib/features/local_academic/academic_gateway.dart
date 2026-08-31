import '../../models/edu_academic_situation.dart';
import '../../models/edu_credit_requirement.dart';
import '../../models/edu_grade.dart';
import '../../providers/edu_provider.dart';

/// 教务读取边界。
///
/// 该接口沿用旧 [EduProvider] 的返回模型，便于页面在迁移期间只替换
/// 依赖注入而不同时改动 UI。实现不得在本地失败时隐式调用另一套实现。
abstract interface class AcademicGateway {
  /// 当前设备学校会话的最小状态，不包含密码、Cookie 或原始响应。
  AcademicSessionSnapshot get session;

  Future<AcademicSessionSnapshot> readSession();

  Future<OperationResult<bool>> login(
    String studentId,
    String password, {
    bool rememberPassword = false,
    bool eduDataConsentAccepted = true,
  });

  Future<OperationResult<List<Map<String, dynamic>>>?> getCourses(
    String year,
    int semester,
  );

  Future<OperationResult<List<EduGrade>>> fetchGrades(
    String year,
    int semester,
  );

  Future<OperationResult<List<Map<String, dynamic>>>> fetchExams({
    String? year,
    int? semester,
  });

  Future<OperationResult<EduAcademicSituation>> fetchAcademicSituation();

  Future<OperationResult<EduCreditRequirementOverview>>
      fetchCreditRequirements();

  Future<OperationResult<void>> logoutSession();

  Future<void> close();
}

/// 不携带学校个人数据的会话状态快照。
class AcademicSessionSnapshot {
  const AcademicSessionSnapshot({
    required this.state,
    this.studentId = '',
    this.displayName = '',
    this.grade = '',
    this.college = '',
    this.major = '',
  });

  final AcademicSessionState state;
  final String studentId;
  final String displayName;
  final String grade;
  final String college;
  final String major;

  bool get isActive => state == AcademicSessionState.active;

  @override
  String toString() => 'AcademicSessionSnapshot(state: $state, '
      'studentId: <redacted>)';
}

enum AcademicSessionState {
  idle,
  loggingIn,
  active,
  relogging,
  expired,
  loggedOut,
}

/// 迁移期远程适配器。
///
/// 该类只转发既有 [EduProvider] 方法，不增加新的服务端路由。PR10a 删除
/// 远程学校能力时应连同本适配器和注册点一并移除。
class RemoteAcademicGateway implements AcademicGateway {
  RemoteAcademicGateway(this.provider);

  final EduProvider provider;

  @override
  AcademicSessionSnapshot get session => _snapshot();

  @override
  Future<AcademicSessionSnapshot> readSession() async {
    await provider.ensureStatusLoaded();
    return _snapshot();
  }

  @override
  Future<OperationResult<bool>> login(
    String studentId,
    String password, {
    bool rememberPassword = false,
    bool eduDataConsentAccepted = true,
  }) async {
    // 远程适配器保留旧 Provider 的同意参数；rememberPassword 由本地实现
    // 处理，这里不把它转换成服务器字段。
    final success = await provider.bind(
      studentId,
      password,
      eduDataConsentAccepted: eduDataConsentAccepted,
    );
    return OperationResult<bool>.ok(success);
  }

  @override
  Future<OperationResult<List<Map<String, dynamic>>>?> getCourses(
    String year,
    int semester,
  ) => provider.getCourses(year, semester);

  @override
  Future<OperationResult<List<EduGrade>>> fetchGrades(
    String year,
    int semester,
  ) => provider.fetchGrades(year, semester);

  @override
  Future<OperationResult<List<Map<String, dynamic>>>> fetchExams({
    String? year,
    int? semester,
  }) async {
    // 旧 Provider 没有考试读取方法；明确返回 unsupported，不能猜测服务端
    // 路由，也不能把失败转成空列表。
    return OperationResult.fail('远程适配器未提供考试读取能力',
        errorCode: 'unsupported');
  }

  @override
  Future<OperationResult<EduAcademicSituation>> fetchAcademicSituation() =>
      provider.fetchAcademicSituation();

  @override
  Future<OperationResult<EduCreditRequirementOverview>>
      fetchCreditRequirements() => provider.fetchCreditRequirements();

  @override
  Future<OperationResult<void>> logoutSession() => provider.logoutSession();

  @override
  Future<void> close() async {
    // EduProvider 的生命周期由 Provider 容器管理，适配器不能擅自关闭其
    // 共享 Dio 或清除其他页面状态。
  }

  AcademicSessionSnapshot _snapshot() {
    return AcademicSessionSnapshot(
      state: _mapState(provider.sessionState),
      studentId: provider.studentId,
      displayName: provider.name,
      grade: provider.grade,
      college: provider.college,
      major: provider.major,
    );
  }

  static AcademicSessionState _mapState(String value) {
    return switch (value.trim().toLowerCase()) {
      'active' => AcademicSessionState.active,
      'logging_in' || 'loggingin' => AcademicSessionState.loggingIn,
      'relogging' => AcademicSessionState.relogging,
      'expired' => AcademicSessionState.expired,
      'logged_out' || 'loggedout' => AcademicSessionState.loggedOut,
      _ => AcademicSessionState.idle,
    };
  }
}

/// 兼容旧命名；保留显式类型名方便迁移清单和静态扫描定位删除点。
typedef EduProviderAcademicGateway = RemoteAcademicGateway;
