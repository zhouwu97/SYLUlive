import '../../../campus_data/storage/academic_cache_store.dart';
import '../../../campus_data/storage/account_scoped_snapshot_store.dart';
import '../../../campus_data/storage/erke_cache_store.dart';
import '../../../campus_data/storage/physical_cache_store.dart';
import '../../../campus_data/storage/schedule_cache_store.dart';
import '../../../academic/storage/academic_persistence_gate.dart';
import '../../../../services/account_session_cleanup_coordinator.dart';
import '../adapters/academic_gateway_adapter.dart';
import '../adapters/erke_gateway_adapter.dart';
import '../adapters/physical_gateway_adapter.dart';
import '../adapters/schedule_gateway_adapter.dart';
import '../models/academic_overview.dart';
import '../models/academic_records.dart';
import '../models/erke_overview.dart';
import '../models/physical_overview.dart';
import '../models/schedule_overview.dart';
import 'gateway_error.dart';
import 'gateway_result.dart';
import 'personal_account_context.dart';
import 'personal_data_gateway.dart';

/// 为当前认证上下文创建 Gateway；不接受模型传入的用户标识。
class PersonalDataGatewayFactory {
  PersonalDataGatewayFactory({
    AccountSessionCleanupCoordinator? cleanupCoordinator,
    AccountScopedSnapshotStore Function(PersonalAccountContext context)?
        snapshotStoreBuilder,
  })  : _cleanupCoordinator =
            cleanupCoordinator ?? AccountSessionCleanupCoordinator.instance,
        _snapshotStoreBuilder = snapshotStoreBuilder;

  final AccountSessionCleanupCoordinator _cleanupCoordinator;
  final AccountScopedSnapshotStore Function(PersonalAccountContext context)?
      _snapshotStoreBuilder;

  PersonalDataGateway create(
    PersonalAccountContext context, {
    AcademicDataRefresher? refreshAcademicData,
  }) {
    final snapshotStore = _snapshotStoreBuilder?.call(context) ??
        AesGcmAccountScopedSnapshotStore(appUserId: context.appUserId);
    final erkeStore = ErkeCacheStore(
      appUserId: context.appUserId,
      sourceAccountId: context.sourceAccountId,
      snapshotStore: snapshotStore,
    );
    final physicalStore = PhysicalCacheStore(
      appUserId: context.appUserId,
      sourceAccountId: context.sourceAccountId,
      snapshotStore: snapshotStore,
    );
    final scheduleStore = ScheduleCacheStore(
      appUserId: context.appUserId,
      sourceAccountId: context.sourceAccountId,
      snapshotStore: snapshotStore,
      persistenceGate: RegistryAcademicPersistenceGate(context.appUserId),
    );
    final academicStore = AcademicCacheStore(
      appUserId: context.appUserId,
      sourceAccountId: context.sourceAccountId,
      snapshotStore: snapshotStore,
      persistenceGate: RegistryAcademicPersistenceGate(context.appUserId),
    );
    return PersonalDataGatewayImpl(
      context: context,
      snapshotStore: snapshotStore,
      erkeAdapter: ErkeGatewayAdapter(
        snapshotStore: snapshotStore,
        context: context,
        needsResync: erkeStore.needsResync,
      ),
      physicalAdapter: PhysicalGatewayAdapter(
        snapshotStore: snapshotStore,
        context: context,
        needsResync: physicalStore.needsResync,
      ),
      scheduleAdapter: ScheduleGatewayAdapter(
        cacheStore: scheduleStore,
        needsResync: scheduleStore.needsResync,
      ),
      academicAdapter: AcademicGatewayAdapter(
        cacheStore: academicStore,
        refreshData: refreshAcademicData,
      ),
      cleanupCoordinator: _cleanupCoordinator,
    );
  }
}

class PersonalDataGatewayImpl implements PersonalDataGateway {
  PersonalDataGatewayImpl({
    required PersonalAccountContext context,
    required AccountScopedSnapshotStore snapshotStore,
    required ErkeGatewayAdapter erkeAdapter,
    required PhysicalGatewayAdapter physicalAdapter,
    required ScheduleGatewayAdapter scheduleAdapter,
    required AcademicGatewayAdapter academicAdapter,
    AccountSessionCleanupCoordinator? cleanupCoordinator,
  })  : _context = context,
        _snapshotStore = snapshotStore,
        _erkeAdapter = erkeAdapter,
        _physicalAdapter = physicalAdapter,
        _scheduleAdapter = scheduleAdapter,
        _academicAdapter = academicAdapter,
        _cleanupCoordinator = cleanupCoordinator {
    _cleanupCoordinator?.register(this, close);
  }

  final PersonalAccountContext _context;
  final AccountScopedSnapshotStore _snapshotStore;
  final ErkeGatewayAdapter _erkeAdapter;
  final PhysicalGatewayAdapter _physicalAdapter;
  final ScheduleGatewayAdapter _scheduleAdapter;
  final AcademicGatewayAdapter _academicAdapter;
  final AccountSessionCleanupCoordinator? _cleanupCoordinator;

  bool _closed = false;
  int _generation = 0;

  @override
  Future<GatewayResult<ErkeOverview>> getErkeOverview() {
    return _read(_erkeAdapter.loadOverview, '二课');
  }

  @override
  Future<GatewayResult<PhysicalOverview>> getPhysicalOverview() {
    return _read(_physicalAdapter.loadOverview, '体测');
  }

  @override
  Future<GatewayResult<ScheduleOverview>> getScheduleOverview({
    required DateTime start,
    required DateTime end,
  }) {
    return _read(
      () => _scheduleAdapter.loadOverview(start: start, end: end),
      '课表',
    );
  }

  @override
  Future<GatewayResult<AcademicOverview>> getAcademicOverview() {
    return _read(_academicAdapter.loadOverview, '成绩');
  }

  @override
  Future<GatewayResult<AcademicRecords>> getAcademicRecords() {
    return _read(_academicAdapter.loadRecords, '成绩明细');
  }

  Future<GatewayResult<T>> _read<T>(
    Future<GatewayResult<T>> Function() operation,
    String dataName,
  ) async {
    if (_closed) return _closedResult<T>(dataName);
    if (_snapshotStore.accountFingerprint != _context.appUserFingerprint) {
      return _accountMismatchResult<T>(dataName);
    }
    final generation = _generation;
    final result = await operation();
    if (_closed || generation != _generation) return _closedResult<T>(dataName);
    return result;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _cleanupCoordinator?.unregister(this);
    await _snapshotStore.close();
  }

  GatewayResult<T> _closedResult<T>(String dataName) {
    return GatewayResult<T>(
      status: GatewayStatus.closed,
      source: PersonalDataSource.none,
      warnings: <String>['$dataName账号上下文已关闭'],
      error: const GatewayError(GatewayErrorCode.closed, '账号上下文已关闭'),
    );
  }

  GatewayResult<T> _accountMismatchResult<T>(String dataName) {
    return GatewayResult<T>(
      status: GatewayStatus.accountMismatch,
      source: PersonalDataSource.none,
      warnings: <String>['$dataName账号上下文不匹配'],
      error: const GatewayError(GatewayErrorCode.accountMismatch, '账号上下文不匹配'),
    );
  }
}
