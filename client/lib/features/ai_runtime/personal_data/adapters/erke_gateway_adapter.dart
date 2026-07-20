import '../../../campus_data/storage/account_scoped_snapshot_store.dart';
import '../../../campus_data/storage/personal_snapshot_models.dart';
import '../gateway/gateway_error.dart';
import '../gateway/gateway_result.dart';
import '../gateway/personal_account_context.dart';
import '../models/erke_overview.dart';

class ErkeGatewayAdapter {
  ErkeGatewayAdapter({
    required AccountScopedSnapshotStore snapshotStore,
    required PersonalAccountContext context,
    Future<bool> Function()? needsResync,
  })  : _snapshotStore = snapshotStore,
        _context = context,
        _needsResync = needsResync;

  final AccountScopedSnapshotStore _snapshotStore;
  final PersonalAccountContext _context;
  final Future<bool> Function()? _needsResync;

  Future<GatewayResult<ErkeOverview>> loadOverview() async {
    try {
      final snapshot = await _snapshotStore.read(
        type: PersonalDataType.erke,
        sourceSystem: 'erke',
        sourceAccountId: _context.sourceAccountId,
      );
      if (snapshot == null) {
        final needsRefresh = await _needsRefresh();
        return GatewayResult<ErkeOverview>(
          status:
              needsRefresh ? GatewayStatus.needsRefresh : GatewayStatus.missing,
          source: PersonalDataSource.none,
          warnings:
              needsRefresh ? const <String>['二课本地数据需要重新同步'] : const <String>[],
        );
      }
      final overview = ErkeOverview.fromPayload(snapshot.payload);
      return _availableResult(snapshot, overview);
    } on PersonalSnapshotStoreException {
      return GatewayResult<ErkeOverview>(
        status: GatewayStatus.corrupted,
        source: PersonalDataSource.none,
        warnings: const <String>['二课本地加密数据无法验证，请重新同步'],
        error: const GatewayError(GatewayErrorCode.corrupted, '二课本地数据不可用'),
      );
    } on FormatException {
      return GatewayResult<ErkeOverview>(
        status: GatewayStatus.corrupted,
        source: PersonalDataSource.none,
        warnings: const <String>['二课本地数据格式无效，请重新同步'],
        error: const GatewayError(GatewayErrorCode.corrupted, '二课本地数据不可用'),
      );
    } catch (_) {
      return GatewayResult<ErkeOverview>(
        status: GatewayStatus.corrupted,
        source: PersonalDataSource.none,
        warnings: const <String>['二课本地数据读取失败，请重新同步'],
        error: const GatewayError(GatewayErrorCode.corrupted, '二课本地数据不可用'),
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

  GatewayResult<ErkeOverview> _availableResult(
    PersonalSnapshot snapshot,
    ErkeOverview overview,
  ) {
    final stale = snapshot.isStale;
    return GatewayResult<ErkeOverview>(
      data: overview,
      status: stale ? GatewayStatus.stale : GatewayStatus.available,
      source: PersonalDataSource.localEncryptedVault,
      fetchedAt: snapshot.fetchedAt,
      expiresAt: snapshot.expiresAt,
      isStale: stale,
      warnings: stale ? const <String>['二课数据已过期，建议先同步'] : const <String>[],
    );
  }
}
