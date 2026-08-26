import '../ai_runtime/personal_data/gateway/gateway_result.dart';
import '../ai_runtime/personal_data/gateway/personal_data_gateway.dart';

/// 设备侧可自动化的数据类型。该枚举只描述数据类别，不包含账号、凭据或原始页面。
enum PersonalDataType {
  academic,
  academicSituation,
  creditRequirements,
  schedule,
  erke,
}

/// 只暴露新鲜度元数据，避免 freshness 检查越过 PersonalDataGateway 读取原始快照。
class FreshnessState {
  const FreshnessState({
    required this.fetchedAt,
    required this.expiresAt,
    required this.isStale,
  });

  final DateTime? fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;

  bool isFreshAt(DateTime now, Duration maxAge) {
    final fetched = fetchedAt;
    if (isStale || fetched == null) return false;
    if (expiresAt != null && !expiresAt!.isAfter(now)) return false;
    return now.difference(fetched) <= maxAge;
  }
}

class RefreshResult {
  const RefreshResult({
    required this.performed,
    this.message,
  });

  final bool performed;
  final String? message;

  bool get succeeded => message == null;
}

typedef DeviceDataQuery<T> = Future<GatewayResult<T>> Function(
  PersonalDataGateway gateway,
);

/// Reader 与刷新执行器之间的安全边界。
///
/// [PersonalDataGateway] 仍然是唯一的结构化只读入口；刷新闭包只由设备上下文
/// 注入，模型无法传入 URL、账号或凭据。所有结果最后仍回到 Gateway 的 typed result。
abstract interface class DeviceAutomationGateway {
  Future<FreshnessState> inspect(PersonalDataType type);

  Future<GatewayResult<Map<String, dynamic>>> readAcademicDataset(
    String dataset,
  );

  Future<RefreshResult> refreshAcademic();

  Future<RefreshResult> refreshAcademicSituation();

  Future<RefreshResult> refreshCreditRequirements();

  Future<RefreshResult> refreshSchedule();

  Future<RefreshResult> refreshErke();

  Future<EnsureFreshResult> ensureFresh(
    PersonalDataType type, {
    required Duration maxAge,
  });

  Future<AcademicBundleEnsureResult> ensureFreshAcademicBundle({
    required Map<String, Duration> maxAges,
  });

  Future<GatewayResult<T>> read<T>(DeviceDataQuery<T> query);

  Future<void> close();
}

class PersonalDataDeviceAutomationGateway implements DeviceAutomationGateway {
  PersonalDataDeviceAutomationGateway({
    required PersonalDataGateway reader,
    Future<RefreshResult> Function()? refreshAcademic,
    Future<RefreshResult> Function()? refreshAcademicSituation,
    Future<RefreshResult> Function()? refreshCreditRequirements,
    Future<RefreshResult> Function()? refreshSchedule,
    Future<RefreshResult> Function()? refreshErke,
    Future<GatewayResult<Map<String, dynamic>>> Function(String dataset)?
        readAcademicDataset,
    DateTime Function()? now,
  })  : _reader = reader,
        _refreshAcademic = refreshAcademic,
        _refreshAcademicSituation = refreshAcademicSituation,
        _refreshCreditRequirements = refreshCreditRequirements,
        _refreshSchedule = refreshSchedule,
        _refreshErke = refreshErke,
        _readAcademicDataset = readAcademicDataset,
        _now = now ?? DateTime.now;

  final PersonalDataGateway _reader;
  final Future<RefreshResult> Function()? _refreshAcademic;
  final Future<RefreshResult> Function()? _refreshAcademicSituation;
  final Future<RefreshResult> Function()? _refreshCreditRequirements;
  final Future<RefreshResult> Function()? _refreshSchedule;
  final Future<RefreshResult> Function()? _refreshErke;
  final Future<GatewayResult<Map<String, dynamic>>> Function(String dataset)?
      _readAcademicDataset;
  final DateTime Function() _now;

  @override
  Future<FreshnessState> inspect(PersonalDataType type) async {
    final result = switch (type) {
      PersonalDataType.academic => await _reader.getAcademicOverview(),
      PersonalDataType.academicSituation =>
        await readAcademicDataset('academic_situation'),
      PersonalDataType.creditRequirements =>
        await readAcademicDataset('credit_requirements'),
      PersonalDataType.schedule => await _reader.getScheduleOverview(
          start: _startOfWeek(_now()),
          end: _startOfWeek(_now()).add(const Duration(days: 6)),
        ),
      PersonalDataType.erke => await _reader.getErkeOverview(),
    };
    return FreshnessState(
      fetchedAt: result.fetchedAt,
      expiresAt: result.expiresAt,
      isStale: result.isStale || result.status == GatewayStatus.stale,
    );
  }

  @override
  Future<GatewayResult<Map<String, dynamic>>> readAcademicDataset(
    String dataset,
  ) async {
    final reader = _readAcademicDataset;
    if (reader == null) {
      return GatewayResult<Map<String, dynamic>>(
        status: GatewayStatus.missing,
        source: PersonalDataSource.none,
      );
    }
    return reader(dataset);
  }

  /// 设备在执行前再次判断 freshness，服务器传入的 maxAge 只能被本地策略收窄。
  @override
  Future<EnsureFreshResult> ensureFresh(
    PersonalDataType type, {
    required Duration maxAge,
  }) async {
    final before = await inspect(type);
    if (before.isFreshAt(_now(), maxAge)) {
      return EnsureFreshResult(before: before, after: before);
    }

    final refresh = switch (type) {
      PersonalDataType.academic => await refreshAcademic(),
      PersonalDataType.academicSituation => await _refreshDataset(
          _refreshAcademicSituation,
          '学业情况',
        ),
      PersonalDataType.creditRequirements => await _refreshDataset(
          _refreshCreditRequirements,
          '学分要求',
        ),
      PersonalDataType.schedule => await refreshSchedule(),
      PersonalDataType.erke => await refreshErke(),
    };
    final after = await inspect(type);
    return EnsureFreshResult(
      before: before,
      after: after,
      refreshPerformed: refresh.performed,
      warning: refresh.message,
    );
  }

  @override
  Future<AcademicBundleEnsureResult> ensureFreshAcademicBundle({
    required Map<String, Duration> maxAges,
  }) async {
    final items = <String, EnsureFreshResult>{};
    for (final entry in maxAges.entries) {
      final type = switch (entry.key) {
        'grades' => PersonalDataType.academic,
        'academic_situation' => PersonalDataType.academicSituation,
        'credit_requirements' => PersonalDataType.creditRequirements,
        _ => throw ArgumentError('不支持的学业数据集: ${entry.key}'),
      };
      final item = await ensureFresh(type, maxAge: entry.value);
      if (!item.after.isFreshAt(_now(), entry.value)) {
        throw StateError('${entry.key}刷新后仍未达到新鲜度要求');
      }
      items[entry.key] = item;
    }
    return AcademicBundleEnsureResult(items: items);
  }

  @override
  Future<RefreshResult> refreshAcademic() {
    final refresh = _refreshAcademic;
    if (refresh != null) return refresh();
    return Future.value(
      const RefreshResult(performed: false, message: '设备暂未配置成绩刷新能力'),
    );
  }

  @override
  Future<RefreshResult> refreshAcademicSituation() => _refreshDataset(
        _refreshAcademicSituation,
        '学业情况',
      );

  @override
  Future<RefreshResult> refreshCreditRequirements() => _refreshDataset(
        _refreshCreditRequirements,
        '学分要求',
      );

  Future<RefreshResult> _refreshDataset(
    Future<RefreshResult> Function()? refresh,
    String label,
  ) {
    if (refresh != null) return refresh();
    return Future.value(
      RefreshResult(performed: false, message: '$label刷新能力未配置'),
    );
  }

  @override
  Future<RefreshResult> refreshSchedule() {
    final refresh = _refreshSchedule;
    if (refresh != null) return refresh();
    return Future.value(
      const RefreshResult(performed: false, message: '设备暂未配置课表刷新能力'),
    );
  }

  @override
  Future<RefreshResult> refreshErke() {
    final refresh = _refreshErke;
    if (refresh != null) return refresh();
    return Future.value(
      const RefreshResult(performed: false, message: '二课刷新需要单独的设备授权'),
    );
  }

  @override
  Future<GatewayResult<T>> read<T>(DeviceDataQuery<T> query) => query(_reader);

  @override
  Future<void> close() => _reader.close();

  static DateTime _startOfWeek(DateTime value) {
    final date = DateTime(value.year, value.month, value.day);
    return date.subtract(Duration(days: date.weekday - 1));
  }
}

class EnsureFreshResult {
  const EnsureFreshResult({
    required this.before,
    required this.after,
    this.refreshPerformed = false,
    this.warning,
  });

  final FreshnessState before;
  final FreshnessState after;
  final bool refreshPerformed;
  final String? warning;
}

class AcademicBundleEnsureResult {
  const AcademicBundleEnsureResult({required this.items});

  final Map<String, EnsureFreshResult> items;
}
