import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import '../domain/academic_provider.dart';
import '../domain/academic_repository.dart';
import '../domain/academic_failure.dart';
import 'academic_identity_client.dart';
import 'provider_academic_repository.dart';

/// 运行时 Provider 路由。默认保留服务端绑定查询，身份验证确认后可切换
/// 到指定本机 Provider；切换时销毁旧 Provider，避免跨身份复用 Cookie。
final class AcademicProviderRouterRepository implements AcademicRepository {
  AcademicProviderRouterRepository({
    required this.legacy,
    required this.registry,
    this.identityClient,
    this.providerIdLoader,
  });

  final AcademicRepository legacy;
  final AcademicProviderRegistry registry;
  final AcademicIdentityClient? identityClient;
  final AcademicProviderId? Function()? providerIdLoader;
  String? _appUserId;
  int _contextGeneration = 0;
  ProviderAcademicRepository? _selected;
  List<AcademicIdentityBinding> _identityBindings = const [];
  bool _identityListLoaded = false;
  bool _closed = false;

  AcademicRepository get _active => _selected ?? legacy;
  AcademicProviderId? get selectedProviderId => _selected?.provider.id;
  AcademicIdentityKey? get selectedIdentity => _selected?.provider.identity;
  AcademicProvider? get selectedProvider => _selected?.provider;
  List<AcademicIdentityBinding> get identityBindings => _identityBindings;
  int get contextGeneration => _contextGeneration;

  /// 读取当前已选本机 Provider 的学校学期列表。
  ///
  /// 路由仓储对外隐藏具体 Provider，但学期选择器仍需拿到学校原始
  /// term 标识；因此只在已选本机身份时向下转发，不走旧服务端代理。
  Future<List<AcademicTerm>> fetchTerms() async {
    _ensureOpen();
    final selected = _selected;
    if (selected == null) {
      throw const AcademicFailure(
        kind: AcademicFailureKind.unauthenticated,
        message: '本机教务身份尚未选择',
        code: 'ACADEMIC_PROVIDER_NOT_SELECTED',
      );
    }
    return selected.fetchTerms();
  }

  /// 读取服务端已经确认的身份；列表本身只保留 provider 和学号，不保留
  /// challenge、密码或学校会话材料。
  Future<List<AcademicIdentityBinding>> loadIdentityBindings({
    bool force = false,
  }) async {
    final client = identityClient;
    final appUserId = _appUserId;
    final contextGeneration = _contextGeneration;
    if (client == null || appUserId == null || appUserId.isEmpty) {
      return const <AcademicIdentityBinding>[];
    }
    if (_identityListLoaded && !force) return _identityBindings;
    final bindings = await client.listIdentities();
    // 身份列表请求可能跨越 App 账号切换；旧账号的响应不能写入新账号
    // 的缓存，也不能继续参与 Provider 选择。
    if (_appUserId != appUserId ||
        _contextGeneration != contextGeneration ||
        _closed) {
      return const <AcademicIdentityBinding>[];
    }
    _identityBindings = List<AcademicIdentityBinding>.unmodifiable(bindings);
    _identityListLoaded = true;
    return _identityBindings;
  }

  /// 启动恢复先用服务端身份列表选定 Provider，再由控制器尝试对应身份的
  /// 本地会话保险箱。旧接口没有 provider_id 时继续保留兼容路径。
  Future<bool> ensureIdentitySelection() async {
    if (_selected != null) return true;
    final appUserId = _appUserId;
    final contextGeneration = _contextGeneration;
    if (appUserId == null || appUserId.isEmpty) return false;
    final bindings = await loadIdentityBindings();
    if (_closed ||
        _appUserId != appUserId ||
        _contextGeneration != contextGeneration ||
        bindings.isEmpty) {
      return false;
    }
    final preferredProvider = providerIdLoader?.call();
    final selected = bindings.firstWhere(
      (binding) => binding.providerId == preferredProvider,
      orElse: () => bindings.first,
    );
    await selectProvider(
      selected.toIdentity(appUserId),
      expectedContextGeneration: contextGeneration,
    );
    return _appUserId == appUserId &&
        _contextGeneration == contextGeneration &&
        _selected != null;
  }

  Future<void> selectProvider(
    AcademicIdentityKey identity, {
    int? expectedContextGeneration,
  }) async {
    _ensureOpen();
    final appUserId = _appUserId;
    if (expectedContextGeneration != null &&
        expectedContextGeneration != _contextGeneration) {
      return;
    }
    if (appUserId == null || identity.appUserId.trim() != appUserId.trim()) {
      throw StateError('教务身份与当前 App 账号不匹配');
    }
    if (_selected?.provider.identity == identity) return;
    final next = ProviderAcademicRepository(registry.create(identity));
    final old = _selected;
    _selected = next;
    await old?.resetSession();
    if (expectedContextGeneration != null &&
        expectedContextGeneration != _contextGeneration) {
      if (identical(_selected, next)) _selected = null;
      next.close();
      return;
    }
    old?.close();
  }

  void syncAppUser(String? appUserId) {
    final next = appUserId?.trim().isEmpty == true ? null : appUserId?.trim();
    if (_appUserId == next) return;
    _contextGeneration++;
    // 账号切换必须立刻丢弃旧身份和 Provider；否则下一位 App 账号会在
    // 读取服务端身份列表前继续复用上一位账号的学校 Cookie。
    final old = _selected;
    _selected = null;
    old?.close();
    _appUserId = next;
    _identityBindings = const [];
    _identityListLoaded = false;
  }

  /// 断开本机会话时也要使同一 App 账号的在途恢复失效；仅比较学号或
  /// App 用户 ID 无法区分断开前后的两次登录代际。
  void invalidateContext() {
    _contextGeneration++;
    final old = _selected;
    _selected = null;
    old?.close();
    _identityBindings = const [];
    _identityListLoaded = false;
  }

  Future<void> clearSelectedProvider() async {
    final old = _selected;
    _selected = null;
    await old?.resetSession();
    old?.close();
  }

  @override
  AcademicSourceKind get sourceKind => _active.sourceKind;
  @override
  AcademicCapabilities get capabilities => _active.capabilities;
  @override
  SessionState get sessionState => _active.sessionState;
  @override
  String? get studentId => _active.studentId;
  @override
  String get sourceName => _active.sourceName;

  @override
  Future<void> switchSource(AcademicSourceKind source) async {
    _ensureOpen();
    if (source == AcademicSourceKind.legacy) {
      await clearSelectedProvider();
      return;
    }
    if (_selected == null) throw StateError('本机 Provider 尚未选择身份');
  }

  @override
  Future<LoginResult> login(
          {required String studentId, required String password}) =>
      _active.login(studentId: studentId, password: password);
  @override
  Future<CaptchaChallenge> getCaptchaChallenge() =>
      _active.getCaptchaChallenge();
  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) =>
      _active.continueLoginWithCaptcha(code: code);
  @override
  Future<StudentProfile> getProfile() => _active.getProfile();
  @override
  Future<CourseFetchResult> getCourses(
          {required String year,
          required int semester,
          String? providerTermId}) =>
      _active.getCourses(
        year: year,
        semester: semester,
        providerTermId: providerTermId,
      );
  @override
  Future<GradeFetchResult> getGrades(
          {required String year, required int semester}) =>
      _active.getGrades(year: year, semester: semester);
  @override
  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) =>
      _active.getGradeDetail(
        year: year,
        semester: semester,
        classId: classId,
        courseName: courseName,
        courseId: courseId,
        studentGradeId: studentGradeId,
      );
  @override
  Future<AcademicSituation> getAcademicSituation() =>
      _active.getAcademicSituation();
  @override
  Future<CreditRequirement> getCreditRequirements() =>
      _active.getCreditRequirements();
  @override
  Future<void> resetSession() => _active.resetSession();
  @override
  Future<void> restoreSession() async {
    if (_selected == null && _appUserId != null) {
      try {
        if (await ensureIdentitySelection()) {
          // 身份列表只证明服务端已绑定。学校 Cookie 由控制器先尝试本地
          // Artifact；没有本地会话时保持未登录，交给登录协调器重新认证。
          if (_selected!.sessionState == SessionState.authenticated ||
              _selected!.sessionState == SessionState.expired) {
            await _selected!.restoreSession();
          }
          return;
        }
      } on AcademicIdentityApiException catch (error) {
        // 老服务端或身份路由暂不可用时保留旧 /edu/status 兼容恢复；
        // 新路由返回的认证/网络失败不能把已有绑定误判成未绑定。
        if (error.statusCode != 404 &&
            error.code != 'ROUTE_UNSUPPORTED' &&
            error.code != 'AUTHENTICATION_REQUIRED') {
          rethrow;
        }
      }
    }
    if (_selected != null) {
      if (_selected!.sessionState == SessionState.authenticated ||
          _selected!.sessionState == SessionState.expired) {
        await _selected!.restoreSession();
      }
      return;
    }
    await legacy.restoreSession();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _selected?.close();
    legacy.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Academic Provider 路由已关闭');
  }
}
