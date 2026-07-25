import '../models/data_freshness.dart';
import '../../../personal_data_sync/personal_data_source.dart';
import 'gateway_error.dart';

export '../../../personal_data_sync/personal_data_source.dart';

enum GatewayStatus {
  available,
  missing,
  stale,
  needsRefresh,
  accountMismatch,
  corrupted,
  unsupported,
  closed,
}

/// Gateway 的结构化只读结果，不暴露保险箱原始 Payload。
class GatewayResult<T> {
  GatewayResult({
    required this.status,
    required this.source,
    this.data,
    this.fetchedAt,
    this.expiresAt,
    this.isStale = false,
    List<String> warnings = const <String>[],
    this.error,
  }) : warnings = List<String>.unmodifiable(warnings);

  final T? data;
  final GatewayStatus status;
  final PersonalDataSource source;
  final DateTime? fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;
  final List<String> warnings;
  final GatewayError? error;

  bool get hasData => data != null;

  DataFreshness get freshness => DataFreshness(
        fetchedAt: fetchedAt,
        expiresAt: expiresAt,
        isStale: isStale,
      );
}
