import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../campus_data/storage/personal_snapshot_models.dart';
import '../ai_model_provider.dart';
import '../skills/personal_skill.dart';
import 'tool_call_models.dart';

abstract interface class ToolPermissionPrompt {
  Future<ToolPermissionDecision> request(ToolPermissionPreview preview);
}

class ToolPermissionManager {
  ToolPermissionManager({required ToolPermissionPrompt prompt})
      : _prompt = prompt;

  final ToolPermissionPrompt _prompt;
  final Set<String> _sessionGrants = <String>{};

  Future<ToolPermissionDecision> authorize(
      ToolPermissionPreview preview) async {
    if (!preview.containsPersonalData) return ToolPermissionDecision.allowOnce;
    if (preview.sensitivity == SkillSensitivity.low &&
        _sessionGrants.contains(preview.grantKey)) {
      return ToolPermissionDecision.allowSession;
    }
    final decision = await _prompt.request(preview);
    if (decision == ToolPermissionDecision.allowSession &&
        preview.sensitivity != SkillSensitivity.low) {
      return ToolPermissionDecision.allowOnce;
    }
    if (decision == ToolPermissionDecision.allowSession) {
      _sessionGrants.add(preview.grantKey);
    }
    return decision;
  }

  void clearSession() => _sessionGrants.clear();
}

class ToolAuditEntry {
  ToolAuditEntry({
    required this.timestamp,
    required this.skillId,
    required this.permission,
    required this.providerKind,
    required Set<PersonalDataType> dataTypes,
    required this.status,
  }) : dataTypes = Set<PersonalDataType>.unmodifiable(dataTypes);

  final DateTime timestamp;
  final String skillId;
  final ToolPermissionDecision permission;
  final AIModelProviderKind providerKind;
  final Set<PersonalDataType> dataTypes;
  final String status;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'timestamp': timestamp.toUtc().toIso8601String(),
        'skill_id': skillId,
        'permission': permission.name,
        'provider_type': providerKind.storageValue,
        'data_types': dataTypes.map((item) => item.storageValue).toList(),
        'status': status,
      };
}

abstract interface class ToolAuditSink {
  Future<void> record(ToolAuditEntry entry);
}

class LocalToolAuditStore implements ToolAuditSink {
  LocalToolAuditStore({
    required this.accountFingerprint,
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const int _maximumEntries = 100;
  final String accountFingerprint;
  final Future<SharedPreferences> Function() _preferencesLoader;

  String get _key => 'ai_tool_audit/$accountFingerprint/v1';

  @override
  Future<void> record(ToolAuditEntry entry) async {
    final preferences = await _preferencesLoader();
    final current = preferences.getStringList(_key) ?? <String>[];
    final updated = <String>[jsonEncode(entry.toJson()), ...current]
        .take(_maximumEntries)
        .toList(growable: false);
    await preferences.setStringList(_key, updated);
  }

  Future<List<ToolAuditEntry>> read() async {
    final preferences = await _preferencesLoader();
    final result = <ToolAuditEntry>[];
    for (final raw in preferences.getStringList(_key) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final map = Map<String, dynamic>.from(decoded);
        final timestamp = DateTime.tryParse(map['timestamp']?.toString() ?? '');
        final provider = AIModelProviderKindLabel.fromStorage(
          map['provider_type']?.toString(),
        );
        final permission = ToolPermissionDecision.values.firstWhere(
          (item) => item.name == map['permission'],
        );
        final types = (map['data_types'] as List? ?? const <Object>[])
            .map((item) => PersonalDataTypeStorage.fromStorage('$item'))
            .toSet();
        if (timestamp == null) continue;
        result.add(
          ToolAuditEntry(
            timestamp: timestamp,
            skillId: map['skill_id']?.toString() ?? '',
            permission: permission,
            providerKind: provider,
            dataTypes: types,
            status: map['status']?.toString() ?? '',
          ),
        );
      } catch (_) {
        // 单条审计损坏不暴露内容，也不阻断其他记录读取。
      }
    }
    return result;
  }

  Future<void> clear() async {
    final preferences = await _preferencesLoader();
    await preferences.remove(_key);
  }
}
