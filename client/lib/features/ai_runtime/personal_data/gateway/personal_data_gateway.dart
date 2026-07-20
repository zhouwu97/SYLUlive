import '../models/erke_overview.dart';
import '../models/physical_overview.dart';
import 'gateway_result.dart';

/// AI 个人数据的唯一只读入口。
abstract interface class PersonalDataGateway {
  Future<GatewayResult<ErkeOverview>> getErkeOverview();

  Future<GatewayResult<PhysicalOverview>> getPhysicalOverview();

  Future<void> close();
}
