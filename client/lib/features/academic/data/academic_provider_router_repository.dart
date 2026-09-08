import '../storage/academic_storage_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'academic_account_config_client.dart';
import '../storage/local_academic_account_store.dart';
import '../storage/academic_connection_store.dart';
import '../../../platform/contracts/preferences_store.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import '../domain/academic_provider.dart';
import '../domain/academic_repository.dart';
import '../domain/academic_failure.dart';
import 'academic_identity_client.dart';
import 'provider_academic_repository.dart';

/// 本机账号决定运行时 Provider；云端只在后台同步账号配置。
final class AcademicProviderRouterRepository implements AcademicRepository {
  AcademicProviderRouterRepository({
    required this.legacy,
    required this.registry,
    this.identityClient,
    this.configClient,
    this.providerIdLoader,
  });

  final AcademicRepository legacy;
  final AcademicProviderRegistry registry;
  final AcademicIdentityClient? identityClient;
  final AcademicAccountConfigClient? configClient;
  LocalAcademicAccountStore? accountStore;
  Timer? _syncTimer;
  void Function()? onConfigChanged;
  ProviderAcademicRepository? _rollback;
  bool _provisional = false;
  bool get isProvisional => _provisional;
  final AcademicProviderId? Function()? providerIdLoader;
  String? _appUserId;
  int _contextGeneration = 0;
  ProviderAcademicRepository? _selected;
  List<AcademicIdentityBinding> _identityBindings = const [];

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

  /// 兼容现有列表类型；内容来自本机账号，不具有服务端学生认证含义。
  Future<List<AcademicIdentityBinding>> loadIdentityBindings({
    bool force = false,
  }) async {
    final user = _appUserId;
    if (user == null) return const [];
    final preferences = await AppPreferencesStore.getInstance();
    if (_appUserId != user || _closed) return const [];
    final store = accountStore ??= LocalAcademicAccountStore(user, preferences);
    if (!preferences.containsKey(store.key)) {
      // 只迁移明确标注 Provider 的本机投影，不依据学号格式猜本科或研究生。
      final raw = preferences.getString('auth_user');
      if (raw != null) {
        final profile = jsonDecode(raw) as Map;
        final explicitProvider = AcademicProviderId.tryParse(
            profile['academic_provider_id']?.toString() ?? '');
        final student = profile['student_id']?.toString() ?? '';
        if (profile['id'].toString() == user && student.isNotEmpty) {
          for (final provider in AcademicProviderId.values) {
            final identity = AcademicIdentityKey(
                appUserId: user, providerId: provider, studentId: student);
            final connection = AcademicConnectionStore(identity, preferences);
            // 旧版本未序列化 Provider 时，只认完整身份对应的既有本机记录。
            if (explicitProvider == provider || connection.initialized) {
              final enabled = connection.connected;
              await store.importLegacy(identity, enabled: enabled);
            }
          }
        }
      }
    }
    for (final identity in store.identities) {
      await AcademicStoragePreferences(
              appUserId: user, identity: identity, store: preferences)
          .migrateLegacyPreferences();
    }
    if (_appUserId != user || _closed) return const [];
    _identityBindings = store.identities
        .map((identity) => AcademicIdentityBinding(
            providerId: identity.providerId,
            studentId: identity.studentId,
            verified: false))
        .toList();
    unawaited(syncConfiguration());
    return _identityBindings;
  }

  Future<void> syncConfiguration() async {
    final user = _appUserId;
    final store = accountStore;
    if (user == null || store == null || configClient == null || _closed) {
      return;
    }
    bool current() =>
        !_closed && _appUserId == user && identical(accountStore, store);
    try {
      await configClient!.sync(store, current);
      if (current()) {
        for (final identity in store.identities) {
          await AcademicStoragePreferences(
                  appUserId: user, identity: identity, store: store.preferences)
              .migrateLegacyPreferences();
        }
        if (current()) onConfigChanged?.call();
      }
    } catch (_) {
      // Outbox 已落盘；云端故障只影响同步状态，不中断学校请求。
    }
  }

  void markSessionAuthenticated() => _selected?.markSessionAuthenticated();

  Future<void> beginProvisional(AcademicIdentityKey identity) async {
    if (_provisional) await cancelProvisional();
    _rollback = _selected;
    _selected = null;
    _provisional = true;
    await selectProvider(identity);
  }

  void commitProvisional() {
    _rollback?.close();
    _rollback = null;
    _provisional = false;
  }

  Future<void> cancelProvisional() async {
    if (!_provisional) return;
    final candidate = _selected;
    _selected = _rollback;
    _rollback = null;
    _provisional = false;
    candidate?.close();
  }

  /// 启动只读本机账号与选择，学校会话由对应 Provider 的保险箱恢复。
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
    final preferences = await AppPreferencesStore.getInstance();
    if (_closed ||
        _appUserId != appUserId ||
        _contextGeneration != contextGeneration) {
      return false;
    }
    final preferredProvider = accountStore?.activeProvider ??
        AcademicProviderId.tryParse(
            preferences.getString('academic_active_provider_$appUserId') ??
                '') ??
        providerIdLoader?.call();
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
    _rollback?.close();
    _rollback = null;
    _provisional = false;
    _syncTimer?.cancel();
    accountStore = null;
    _appUserId = next;
    if (next != null && configClient != null) {
      _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(syncConfiguration());
      });
    }
    _identityBindings = const [];
  }

  /// 断开本机会话时也要使同一 App 账号的在途恢复失效；仅比较学号或
  /// App 用户 ID 无法区分断开前后的两次登录代际。
  void invalidateContext() {
    _contextGeneration++;
    final old = _selected;
    _selected = null;
    old?.close();
    _identityBindings = const [];
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
  Future<CaptchaChallenge> refreshCaptchaChallenge() =>
      _selected?.refreshCaptchaChallenge() ?? legacy.getCaptchaChallenge();

  @override
  Future<void> resetSession() => _active.resetSession();
  @override
  Future<void> restoreSession() async {
    if (_selected == null && _appUserId != null) {
      // 身份列表为空或读取失败都不能回退服务器代登录。
      await ensureIdentitySelection();
      return;
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
    _syncTimer?.cancel();
    _rollback?.close();
    _selected?.close();
    legacy.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Academic Provider 路由已关闭');
  }
}
