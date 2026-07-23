import '../models/academic_overview.dart';
import '../models/academic_records.dart';
import '../models/erke_overview.dart';
import '../models/physical_overview.dart';
import '../models/schedule_overview.dart';
import 'gateway_result.dart';
import 'personal_data_gateway.dart';

/// 未绑定教务时使用的失败关闭 Gateway；公开 Skill 不会访问它。
class UnavailablePersonalDataGateway implements PersonalDataGateway {
  const UnavailablePersonalDataGateway();

  GatewayResult<T> _unavailable<T>() => GatewayResult<T>(
        status: GatewayStatus.unsupported,
        source: PersonalDataSource.none,
        warnings: const <String>['需要绑定教务后才能读取个人校园数据'],
      );

  @override
  Future<GatewayResult<AcademicOverview>> getAcademicOverview() async =>
      _unavailable();

  @override
  Future<GatewayResult<AcademicRecords>> getAcademicRecords() async =>
      _unavailable();

  @override
  Future<GatewayResult<ErkeOverview>> getErkeOverview() async => _unavailable();

  @override
  Future<GatewayResult<PhysicalOverview>> getPhysicalOverview() async =>
      _unavailable();

  @override
  Future<GatewayResult<ScheduleOverview>> getScheduleOverview({
    required DateTime start,
    required DateTime end,
  }) async =>
      _unavailable();

  @override
  Future<void> close() async {}
}
