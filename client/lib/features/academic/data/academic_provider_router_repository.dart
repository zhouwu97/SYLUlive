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
    this.onIdentityVerified,
    this.configClient,
    this.providerIdLoader,
  });

  final AcademicRepository legacy;
  final AcademicProviderRegistry registry;
  final AcademicIdentityClient? identityClient;
  final Future<void> Function()? onIdentityVerified;
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
  AcademicIdentityReadStatus _serverIdentityStatus =
      AcademicIdentityReadStatus.unknown;
  List<AcademicIdentityBinding> _lastServerIdentityBindings = const [];
  Object? _serverIdentityError;
  DateTime? _serverIdentityLoadedAt;
  Future<void>? _reconcileRunning;
  DateTime? _lastReconcileAttempt;
  int _reconcileForceVersion = 0;
  int _reconcileForceCompletedVersion = 0;
  final Map<AcademicProviderId, AcademicConfigSyncStatus> _configStatuses = {};

  bool _closed = false;

  AcademicRepository get _active => _selected ?? legacy;
  AcademicProviderId? get selectedProviderId => _selected?.provider.id;
  AcademicIdentityKey? get selectedIdentity => _selected?.provider.identity;
  AcademicProvider? get selectedProvider => _selected?.provider;
  List<AcademicIdentityBinding> get identityBindings => _identityBindings;
  int get contextGeneration => _contextGeneration;
  AcademicIdentityReadStatus get serverIdentityStatus => _serverIdentityStatus;
  List<AcademicIdentityBinding> get lastServerIdentityBindings =>
      _lastServerIdentityBindings;
  Object? get serverIdentityError => _serverIdentityError;
  DateTime? get serverIdentityLoadedAt => _serverIdentityLoadedAt;

  AcademicConfigSyncStatus configStatus(AcademicProviderId provider) {
    final transient = _configStatuses[provider];
    if (transient == AcademicConfigSyncStatus.loading ||
        transient == AcademicConfigSyncStatus.error) {
      return transient!;
    }
    return accountStore?.syncStatus(provider) ??
        transient ??
        AcademicConfigSyncStatus.unknown;
  }

  void _resetServerIdentityState() {
    _serverIdentityStatus = AcademicIdentityReadStatus.unknown;
    _lastServerIdentityBindings = const [];
    _serverIdentityError = null;
    _serverIdentityLoadedAt = null;
  }

  void _setConfigStatus(AcademicConfigSyncStatus status) {
    for (final provider in AcademicProviderId.values) {
      _configStatuses[provider] = status;
    }
  }

  void _refreshConfigStatuses({bool clearTransient = false}) {
    final store = accountStore;
    for (final provider in AcademicProviderId.values) {
      if (!clearTransient &&
          (_configStatuses[provider] == AcademicConfigSyncStatus.loading ||
              _configStatuses[provider] == AcademicConfigSyncStatus.error)) {
        continue;
      }
      _configStatuses[provider] =
          store?.syncStatus(provider) ?? AcademicConfigSyncStatus.unknown;
    }
  }

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
    bool scheduleReconcile = true,
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
    if (scheduleReconcile && _reconcileRunning == null) {
      unawaited(reconcileAccountConfiguration());
    }
    return _identityBindings;
  }

  /// 读取服务端可信身份，和本机账号配置保持独立的展示来源。
  Future<List<AcademicIdentityBinding>> loadServerIdentityBindings({
    bool requireSuccess = false,
  }) async {
    final client = identityClient;
    if (client == null) {
      _serverIdentityStatus = AcademicIdentityReadStatus.unknown;
      return _lastServerIdentityBindings;
    }
    final user = _appUserId;
    final generation = _contextGeneration;
    _serverIdentityStatus = AcademicIdentityReadStatus.loading;
    _serverIdentityError = null;
    try {
      final bindings = await client.listIdentities();
      if (_closed || _appUserId != user || _contextGeneration != generation) {
        return _lastServerIdentityBindings;
      }
      _lastServerIdentityBindings = bindings;
      _serverIdentityLoadedAt = DateTime.now().toUtc();
      _serverIdentityStatus = bindings.isEmpty
          ? AcademicIdentityReadStatus.empty
          : AcademicIdentityReadStatus.loaded;
      return bindings;
    } catch (error) {
      if (!_closed && _appUserId == user && _contextGeneration == generation) {
        _serverIdentityError = error;
        _serverIdentityStatus = AcademicIdentityReadStatus.error;
      }
      if (requireSuccess) rethrow;
      // 保留上一次成功读取的展示快照，但由 status 明确标记本次读取失败。
      return _lastServerIdentityBindings;
    }
  }

  Future<void> syncConfiguration({bool requireSuccess = false}) async {
    await _syncConfigurationWithPresence(requireSuccess: requireSuccess);
  }

  Future<Set<AcademicProviderId>?> _syncConfigurationWithPresence(
      {bool requireSuccess = false}) async {
    final user = _appUserId;
    final generation = _contextGeneration;
    final store = accountStore;
    if (user == null || store == null || configClient == null || _closed) {
      return null;
    }
    _setConfigStatus(AcademicConfigSyncStatus.loading);
    bool current() =>
        !_closed &&
        _appUserId == user &&
        identical(accountStore, store) &&
        generation == _contextGeneration;
    try {
      final presentProviders =
          await configClient!.syncWithPresence(store, current);
      if (presentProviders == null) return null;
      if (current()) {
        for (final identity in store.identities) {
          await AcademicStoragePreferences(
                  appUserId: user, identity: identity, store: store.preferences)
              .migrateLegacyPreferences();
        }
        if (current()) {
          _identityBindings = store.identities
              .map((identity) => AcademicIdentityBinding(
                  providerId: identity.providerId,
                  studentId: identity.studentId,
                  verified: false))
              .toList();
          // 新设备恢复配置后挂载对应 Provider，但不恢复密码或替用户登录学校。
          if (_selected == null &&
              !_provisional &&
              generation == _contextGeneration &&
              store.identities.isNotEmpty) {
            final identities = store.identities;
            final identity = identities.firstWhere(
                (identity) => identity.providerId == store.activeProvider,
                orElse: () => identities.first);
            await selectProvider(identity,
                expectedContextGeneration: generation);
          }
          if (current()) onConfigChanged?.call();
        }
      }
      if (current()) _refreshConfigStatuses(clearTransient: true);
      return current() ? presentProviders : null;
    } catch (error) {
      if (current()) _setConfigStatus(AcademicConfigSyncStatus.error);
      // Outbox 已落盘；云端故障只影响同步状态，不中断学校请求。
      if (requireSuccess) rethrow;
    }
    return null;
  }

  /// 在完整读取服务端配置后，把已有本机账号补登记到配置表。
  ///
  /// 先 GET 再决定是否入队：请求失败时保持未知，不会误把网络故障当成
  /// “服务端没有配置”；服务端已有删除墓碑、其他学号或冲突时也不复活。
  Future<void> reconcileAccountConfiguration({
    bool requireSuccess = false,
    bool force = false,
  }) async {
    final user = _appUserId;
    final generation = _contextGeneration;
    if (user == null || configClient == null || _closed) return;
    final requestedForceVersion =
        force ? ++_reconcileForceVersion : _reconcileForceVersion;
    while (true) {
      if (_closed || _appUserId != user || _contextGeneration != generation) {
        return;
      }
      final shared = _reconcileRunning;
      if (shared != null) {
        try {
          await shared;
        } catch (_) {
          // 每个调用方单独决定是否上抛，手动同步不能继承后台任务的吞错策略。
          if (requireSuccess &&
              !_closed &&
              _appUserId == user &&
              _contextGeneration == generation) {
            rethrow;
          }
          return;
        }
        if (_closed || _appUserId != user || _contextGeneration != generation) {
          return;
        }
        // Future 完成和 owner 的 finally 可能处于同一个 microtask；清掉
        // 已完成的指针，避免 force 调用把同一个 Future 当成补跑结果直接返回。
        if (identical(_reconcileRunning, shared)) {
          _reconcileRunning = null;
        }
        // 严格等待者也只等待自己声明的 force 版本；共享任务已经满足
        // 该版本时直接结束，不能因为 requireSuccess=true 绕过合并再跑一轮。
        if (requestedForceVersion <= _reconcileForceCompletedVersion) {
          return;
        }
        continue;
      }

      final forceNeeded =
          requestedForceVersion > _reconcileForceCompletedVersion;
      final lastAttempt = _lastReconcileAttempt;
      if (!forceNeeded &&
          !requireSuccess &&
          lastAttempt != null &&
          DateTime.now().difference(lastAttempt) <
              const Duration(seconds: 30)) {
        return;
      }
      _lastReconcileAttempt = DateTime.now();
      final operationForceVersion = _reconcileForceVersion;
      final operationWasForced =
          operationForceVersion > _reconcileForceCompletedVersion;
      final operation =
          _reconcileAccountConfiguration(user, generation);
      _reconcileRunning = operation;
      try {
        await operation;
        // 同一共享任务期间到达的多个 force 请求由这一轮合并满足，
        // 后续调用只需等待，不再制造请求风暴。
        // 必须核对当前代次与账号仍属于本任务，避免旧任务结束将完成计数写入新账号。
        if (!_closed &&
            _appUserId == user &&
            _contextGeneration == generation) {
          _reconcileForceCompletedVersion = operationWasForced
              ? _reconcileForceVersion
              : operationForceVersion;
        }
      } catch (_) {
        if (!_closed &&
            _appUserId == user &&
            _contextGeneration == generation) {
          if (requireSuccess) rethrow;
        }
      } finally {
        if (identical(_reconcileRunning, operation)) _reconcileRunning = null;
      }
      return;
    }
  }

  Future<void> _reconcileAccountConfiguration(
      String user, int generation) async {
    bool current() =>
        !_closed && _appUserId == user && _contextGeneration == generation;
    await loadIdentityBindings(scheduleReconcile: false);
    if (!current()) return;
    final store = accountStore!;
    final accounts = [
      for (final identity in store.identities)
        (identity: identity, epoch: store.epoch(identity.providerId)),
    ];
    final presentProviders =
        await _syncConfigurationWithPresence(requireSuccess: true);
    if (!current() || presentProviders == null) return;

    var queued = false;
    for (final account in accounts) {
      if (!current()) return;
      final added = await store.ensureRegistrationQueued(
        account.identity,
        expectedEpoch: account.epoch,
        serverConfirmedAbsent:
            !presentProviders.contains(account.identity.providerId),
        current: current,
      );
      queued = queued || added;
    }
    // 读取期间人工登录也可能写入 Outbox，收尾一起发送已持久化的操作。
    final hasPending = store.identities.any((identity) {
      final entry = store.entry(identity.providerId);
      return entry['conflict'] != true &&
          (entry['outbox'] as List? ?? []).isNotEmpty;
    });
    if ((queued || hasPending) && current()) {
      await _syncConfigurationWithPresence(requireSuccess: true);
    }
    if (current()) onConfigChanged?.call();
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
    var bindings = await loadIdentityBindings();
    // 没有本机配置时，必须等待云端查询结束，不能把异步查询尚未返回当成未绑定。
    if (bindings.isEmpty && configClient != null) {
      await syncConfiguration(requireSuccess: true);
      bindings = _identityBindings;
    }
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
    _reconcileRunning = null;
    _lastReconcileAttempt = null;
    _reconcileForceVersion = 0;
    _reconcileForceCompletedVersion = 0;
    accountStore = null;
    _appUserId = next;
    if (next != null && configClient != null) {
      _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(reconcileAccountConfiguration());
      });
    }
    _identityBindings = const [];
    _configStatuses.clear();
    _resetServerIdentityState();
  }

  /// 断开本机会话时也要使同一 App 账号的在途恢复失效；仅比较学号或
  /// App 用户 ID 无法区分断开前后的两次登录代际。
  void invalidateContext() {
    _contextGeneration++;
    _reconcileRunning = null;
    _lastReconcileAttempt = null;
    _reconcileForceVersion = 0;
    _reconcileForceCompletedVersion = 0;
    final old = _selected;
    _selected = null;
    old?.close();
    _identityBindings = const [];
    _configStatuses.clear();
    _resetServerIdentityState();
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
