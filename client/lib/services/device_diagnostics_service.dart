import 'dart:convert';
import 'dart:io';
import 'package:package_info_plus/package_info_plus.dart';

class DeviceDiagnosticsInfo {
  final String appVersion;
  final String buildNumber;
  final String osName;
  final String osVersion;
  final String deviceModel;
  final String networkType;
  final String currentRoute;
  final String submitTime;
  final Map<String, dynamic> rawDetails;

  DeviceDiagnosticsInfo({
    required this.appVersion,
    required this.buildNumber,
    required this.osName,
    required this.osVersion,
    required this.deviceModel,
    required this.networkType,
    required this.currentRoute,
    required this.submitTime,
    required this.rawDetails,
  });

  String get summaryText {
    final osStr = osName.isNotEmpty ? '$osName $osVersion'.trim() : 'Unknown OS';
    final modelStr = deviceModel.isNotEmpty ? deviceModel : 'Device';
    final routeStr = currentRoute.isNotEmpty ? currentRoute : '未知模块';
    return 'App $appVersion · $osStr\n$modelStr · 当前位置：$routeStr';
  }

  String toJsonString() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(rawDetails);
  }
}

class DeviceDiagnosticsService {
  static Future<DeviceDiagnosticsInfo> collect({String? currentRoute}) async {
    String appVersion = '1.7.4';
    String buildNumber = '1707';

    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
      buildNumber = info.buildNumber;
    } catch (_) {
      // fallback
    }

    String osName = 'Unknown';
    String osVersion = '';
    String deviceModel = 'Mobile';

    try {
      if (Platform.isAndroid) {
        osName = 'Android';
        osVersion = Platform.operatingSystemVersion;
        deviceModel = 'Android Device';
      } else if (Platform.isIOS) {
        osName = 'iOS';
        osVersion = Platform.operatingSystemVersion;
        deviceModel = 'iPhone / iPad';
      } else if (Platform.isWindows) {
        osName = 'Windows';
        osVersion = Platform.operatingSystemVersion;
        deviceModel = 'Windows PC';
      } else if (Platform.isMacOS) {
        osName = 'macOS';
        osVersion = Platform.operatingSystemVersion;
        deviceModel = 'Mac';
      } else if (Platform.isLinux) {
        osName = 'Linux';
        osVersion = Platform.operatingSystemVersion;
        deviceModel = 'Linux PC';
      }
    } catch (_) {}

    final now = DateTime.now();
    final submitTimeStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final route = currentRoute ?? '通用反馈';

    // 结构化诊断字典：明确黑名单过滤，绝不包含 Token、Cookie、教务密码等敏感隐私
    final sanitizedMap = <String, dynamic>{
      'app_version': appVersion,
      'build_number': buildNumber,
      'os_name': osName,
      'os_version': osVersion,
      'device_model': deviceModel,
      'current_module': route,
      'submit_time': submitTimeStr,
      'platform_locale': Platform.localeName,
      'screen_scale': 'Standard',
      'privacy_guarantee': '已安全过滤 JWT/Cookie/教务密码/聊天隐私',
    };

    return DeviceDiagnosticsInfo(
      appVersion: appVersion,
      buildNumber: buildNumber,
      osName: osName,
      osVersion: osVersion,
      deviceModel: deviceModel,
      networkType: 'WiFi / Cellular',
      currentRoute: route,
      submitTime: submitTimeStr,
      rawDetails: sanitizedMap,
    );
  }
}
