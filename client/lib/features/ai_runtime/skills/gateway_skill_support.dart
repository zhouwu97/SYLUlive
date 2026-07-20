import '../../campus_data/storage/personal_snapshot_models.dart';
import '../personal_data/gateway/gateway_result.dart';
import 'personal_skill.dart';

SkillEvidence gatewayEvidence<T>(
  GatewayResult<T> result, {
  required PersonalDataType dataType,
  required String scope,
}) {
  final source = switch (result.source) {
    PersonalDataSource.localEncryptedVault => 'local_encrypted_vault',
    PersonalDataSource.none => 'none',
  };
  return SkillEvidence(
    source: source,
    scope: scope,
    dataType: dataType,
    fetchedAt: result.fetchedAt,
    expiresAt: result.expiresAt,
    isStale: result.isStale,
  );
}

SkillResult<O>? gatewayFailure<O, T>(
  GatewayResult<T> result, {
  required String dataLabel,
}) {
  if (result.data != null &&
      (result.status == GatewayStatus.available ||
          result.status == GatewayStatus.stale)) {
    return null;
  }

  final status = switch (result.status) {
    GatewayStatus.missing => SkillStatus.missingData,
    GatewayStatus.needsRefresh ||
    GatewayStatus.stale =>
      SkillStatus.needsRefresh,
    GatewayStatus.unsupported => SkillStatus.invalidInput,
    GatewayStatus.accountMismatch || GatewayStatus.closed => SkillStatus.denied,
    GatewayStatus.corrupted => SkillStatus.unavailable,
    GatewayStatus.available => SkillStatus.unavailable,
  };
  return SkillResult<O>(
    status: status,
    containsPersonalData: false,
    warnings: result.warnings.isNotEmpty
        ? result.warnings
        : <String>['$dataLabel数据不可用'],
  );
}

List<String> mergeWarnings(
  List<String> gatewayWarnings, [
  Iterable<String> extraWarnings = const <String>[],
]) =>
    <String>{...gatewayWarnings, ...extraWarnings}.toList(growable: false);
