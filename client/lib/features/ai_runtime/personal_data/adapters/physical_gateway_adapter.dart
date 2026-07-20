import '../../../campus_data/storage/account_scoped_snapshot_store.dart';
import '../../../campus_data/storage/personal_snapshot_models.dart';
import '../gateway/gateway_error.dart';
import '../gateway/gateway_result.dart';
import '../gateway/personal_account_context.dart';
import '../models/physical_overview.dart';

class PhysicalGatewayAdapter {
  PhysicalGatewayAdapter({
    required AccountScopedSnapshotStore snapshotStore,
    required PersonalAccountContext context,
    Future<bool> Function()? needsResync,
  })  : _snapshotStore = snapshotStore,
        _context = context,
        _needsResync = needsResync;

  final AccountScopedSnapshotStore _snapshotStore;
  final PersonalAccountContext _context;
  final Future<bool> Function()? _needsResync;

  Future<GatewayResult<PhysicalOverview>> loadOverview() async {
    try {
      final snapshot = await _snapshotStore.read(
        type: PersonalDataType.physical,
        sourceSystem: 'physical',
        sourceAccountId: _context.sourceAccountId,
      );
      if (snapshot == null) {
        final needsRefresh = await _needsRefresh();
        return GatewayResult<PhysicalOverview>(
          status:
              needsRefresh ? GatewayStatus.needsRefresh : GatewayStatus.missing,
          source: PersonalDataSource.none,
          warnings:
              needsRefresh ? const <String>['体测本地数据需要重新同步'] : const <String>[],
        );
      }
      final overview = PhysicalOverview.fromPayload(snapshot.payload);
      return _availableResult(snapshot, overview);
    } on PersonalSnapshotStoreException {
      return GatewayResult<PhysicalOverview>(
        status: GatewayStatus.corrupted,
        source: PersonalDataSource.none,
        warnings: const <String>['体测本地加密数据无法验证，请重新同步'],
        error: const GatewayError(GatewayErrorCode.corrupted, '体测本地数据不可用'),
      );
    } on FormatException {
      return GatewayResult<PhysicalOverview>(
        status: GatewayStatus.corrupted,
        source: PersonalDataSource.none,
        warnings: const <String>['体测本地数据格式无效，请重新同步'],
        error: const GatewayError(GatewayErrorCode.corrupted, '体测本地数据不可用'),
      );
    } catch (_) {
      return GatewayResult<PhysicalOverview>(
        status: GatewayStatus.corrupted,
        source: PersonalDataSource.none,
        warnings: const <String>['体测本地数据读取失败，请重新同步'],
        error: const GatewayError(GatewayErrorCode.corrupted, '体测本地数据不可用'),
      );
    }
  }

  Future<bool> _needsRefresh() async {
    try {
      return await _needsResync?.call() ?? false;
    } catch (_) {
      return true;
    }
  }

  GatewayResult<PhysicalOverview> _availableResult(
    PersonalSnapshot snapshot,
    PhysicalOverview overview,
  ) {
    final stale = snapshot.isStale;
    return GatewayResult<PhysicalOverview>(
      data: overview,
      status: stale ? GatewayStatus.stale : GatewayStatus.available,
      source: PersonalDataSource.localEncryptedVault,
      fetchedAt: snapshot.fetchedAt,
      expiresAt: snapshot.expiresAt,
      isStale: stale,
      warnings: stale ? const <String>['体测数据已过期，建议先同步'] : const <String>[],
    );
  }
}
