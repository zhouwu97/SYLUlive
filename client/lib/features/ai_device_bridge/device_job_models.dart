import 'dart:convert';

class DeviceJobApiException implements Exception {
  const DeviceJobApiException(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  @override
  String toString() => 'DeviceJobApiException($code)';
}

class DeviceToolJob {
  DeviceToolJob({
    required this.id,
    required this.toolName,
    required this.arguments,
    required this.requiredDataTypes,
    required this.status,
    required this.stateVersion,
    required this.expiresAt,
  });

  final String id;
  final String toolName;
  final Map<String, dynamic> arguments;
  final List<String> requiredDataTypes;
  final String status;
  final int stateVersion;
  final DateTime expiresAt;

  factory DeviceToolJob.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final toolName = json['tool_name'];
    final arguments = json['arguments'];
    final requiredDataTypes = json['required_data_types'];
    final status = json['status'];
    final stateVersion = json['state_version'];
    final expiresAt = json['expires_at'];
    if (id is! String ||
        id.trim().isEmpty ||
        toolName is! String ||
        toolName.trim().isEmpty ||
        arguments is! Map ||
        requiredDataTypes is! List ||
        status is! String ||
        stateVersion is! num ||
        stateVersion % 1 != 0 ||
        expiresAt is! String) {
      throw const FormatException('设备任务格式无效');
    }
    final parsedExpiry = DateTime.tryParse(expiresAt)?.toUtc();
    if (parsedExpiry == null) throw const FormatException('设备任务过期时间无效');
    final types = <String>[];
    for (final value in requiredDataTypes) {
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('设备任务数据类型无效');
      }
      types.add(value.trim());
    }
    return DeviceToolJob(
      id: id.trim(),
      toolName: toolName.trim(),
      arguments: Map<String, dynamic>.unmodifiable(
        Map<String, dynamic>.from(arguments),
      ),
      requiredDataTypes: List<String>.unmodifiable(types),
      status: status.trim(),
      stateVersion: stateVersion.toInt(),
      expiresAt: parsedExpiry,
    );
  }
}

class DeviceToolExecutionResult {
  DeviceToolExecutionResult(Map<String, dynamic> value)
      : value = _copyJsonMap(value);

  final Map<String, dynamic> value;

  String encode() => jsonEncode(value);
}

Map<String, dynamic> _copyJsonMap(Map<String, dynamic> value) {
  final encoded = jsonEncode(value);
  final decoded = jsonDecode(encoded);
  if (decoded is! Map) throw const FormatException('设备结果格式无效');
  return Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(decoded));
}
