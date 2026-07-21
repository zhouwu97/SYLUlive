import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../campus_data/storage/account_cache_namespace.dart';
import '../../campus_data/storage/personal_snapshot_models.dart';
import '../../../models/ai_chat_message.dart';
import '../skills/personal_skill.dart';

abstract interface class PersonalConversationSecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterPersonalConversationSecureStore
    implements PersonalConversationSecureStore {
  const FlutterPersonalConversationSecureStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class PersonalConversationEntry {
  PersonalConversationEntry({
    required this.message,
    List<SkillEvidence> evidence = const <SkillEvidence>[],
  }) : evidence = List<SkillEvidence>.unmodifiable(evidence);

  final AiChatMessage message;
  final List<SkillEvidence> evidence;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': message.id,
        'request_id': message.requestId,
        'role': message.role.name,
        'content': message.content,
        'status': message.status.name,
        'created_at': message.createdAt.toUtc().toIso8601String(),
        'evidence': evidence
            .map(
              (item) => <String, dynamic>{
                'source': item.source,
                'scope': item.scope,
                if (item.dataType != null)
                  'data_type': item.dataType!.storageValue,
                if (item.fetchedAt != null)
                  'fetched_at': item.fetchedAt!.toUtc().toIso8601String(),
                if (item.expiresAt != null)
                  'expires_at': item.expiresAt!.toUtc().toIso8601String(),
                'is_stale': item.isStale,
              },
            )
            .toList(growable: false),
      };

  static PersonalConversationEntry fromJson(Map<String, dynamic> json) {
    final role = AiMessageRole.values.firstWhere(
      (item) => item.name == json['role'],
    );
    final status = AiMessageStatus.values.firstWhere(
      (item) => item.name == json['status'],
    );
    final createdAt = DateTime.parse(json['created_at'] as String);
    final evidence = (json['evidence'] as List? ?? const <Object>[])
        .map(
            (item) => _evidenceFromJson(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false);
    return PersonalConversationEntry(
      message: AiChatMessage(
        id: json['id'] as String,
        requestId: json['request_id'] as String,
        role: role,
        content: json['content'] as String,
        status: status,
        createdAt: createdAt,
      ),
      evidence: evidence,
    );
  }

  static SkillEvidence _evidenceFromJson(Map<String, dynamic> json) {
    final dataType = json['data_type'];
    return SkillEvidence(
      source: json['source'] as String,
      scope: json['scope'] as String,
      dataType: dataType == null
          ? null
          : PersonalDataTypeStorage.fromStorage(dataType as String),
      fetchedAt: _dateTime(json['fetched_at']),
      expiresAt: _dateTime(json['expires_at']),
      isStale: json['is_stale'] == true,
    );
  }

  static DateTime? _dateTime(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

/// 仅保存最终可见消息和证据摘要，不接受 Tool 调用或原始 Tool Result。
class PersonalConversationStore {
  PersonalConversationStore({
    required String accountKey,
    PersonalConversationSecureStore secureStore =
        const FlutterPersonalConversationSecureStore(),
  })  : _accountFingerprint = AccountCacheNamespace.fingerprint(accountKey),
        _secureStore = secureStore {
    if (_accountFingerprint.isEmpty) {
      throw ArgumentError.value(accountKey, 'accountKey');
    }
  }

  static const int maximumMessages = 20;
  static const int maximumCharacters = 40000;
  static const int _schemaVersion = 1;

  final String _accountFingerprint;
  final PersonalConversationSecureStore _secureStore;
  Future<void> _pendingWrite = Future<void>.value();

  String get _storageKey => 'ai_personal_conversations/$_accountFingerprint/v1';

  Future<List<PersonalConversationEntry>> read() async {
    try {
      final raw = await _secureStore.read(_storageKey);
      if (raw == null || raw.isEmpty) {
        return const <PersonalConversationEntry>[];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['schema_version'] != _schemaVersion) {
        return const <PersonalConversationEntry>[];
      }
      final entries = (decoded['entries'] as List? ?? const <Object>[])
          .map(
            (item) => PersonalConversationEntry.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false);
      return _bounded(entries);
    } catch (_) {
      return const <PersonalConversationEntry>[];
    }
  }

  Future<void> replace(List<PersonalConversationEntry> entries) {
    final bounded = _bounded(entries);
    final encoded = jsonEncode(<String, dynamic>{
      'schema_version': _schemaVersion,
      'entries': bounded.map((item) => item.toJson()).toList(growable: false),
    });
    _pendingWrite = _pendingWrite
        .catchError((_) {})
        .then((_) => _secureStore.write(_storageKey, encoded));
    return _pendingWrite;
  }

  Future<void> clear() {
    _pendingWrite = _pendingWrite
        .catchError((_) {})
        .then((_) => _secureStore.delete(_storageKey));
    return _pendingWrite;
  }

  List<PersonalConversationEntry> _bounded(
    List<PersonalConversationEntry> entries,
  ) {
    final result = entries
        .where((item) => item.message.content.trim().isNotEmpty)
        .toList(growable: true);
    while (result.length > maximumMessages) {
      result.removeAt(0);
    }
    var characters = result.fold<int>(
      0,
      (sum, item) => sum + item.message.content.length,
    );
    while (result.isNotEmpty && characters > maximumCharacters) {
      characters -= result.removeAt(0).message.content.length;
    }
    return List<PersonalConversationEntry>.unmodifiable(result);
  }
}
