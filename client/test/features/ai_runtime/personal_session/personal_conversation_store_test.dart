import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/personal_session/personal_conversation_store.dart';
import 'package:shenliyuan/features/ai_runtime/skills/personal_skill.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';
import 'package:shenliyuan/platform/contracts/blob_store.dart';

void main() {
  test('个人历史按账号隔离并恢复证据摘要', () async {
    final secure = _MemoryPersonalConversationSecureStore();
    final accountA = PersonalConversationStore(
      accountKey: 'app-a::edu-a',
      blobStore: secure,
    );
    final accountB = PersonalConversationStore(
      accountKey: 'app-b::edu-b',
      blobStore: secure,
    );
    await accountA.replace(<PersonalConversationEntry>[
      _entry(
        'assistant',
        AiMessageRole.assistant,
        evidence: const <SkillEvidence>[
          SkillEvidence(
            source: '本地保险箱',
            scope: '学业概览',
            dataType: PersonalDataType.academic,
          ),
        ],
      ),
    ]);

    expect(await accountB.read(), isEmpty);
    final restored = await accountA.read();
    expect(restored.single.message.content, 'assistant');
    expect(restored.single.evidence.single.scope, '学业概览');
  });

  test('历史结构不保存 Tool 调用、参数或原始结果', () async {
    final secure = _MemoryPersonalConversationSecureStore();
    final store = PersonalConversationStore(
      accountKey: 'app-a::edu-a',
      blobStore: secure,
    );
    await store.replace(<PersonalConversationEntry>[
      _entry('请总结我的结果', AiMessageRole.user),
      _entry('最终回答', AiMessageRole.assistant),
    ]);

    final raw = secure.values.values.single;
    expect(raw, isNot(contains('tool_call')));
    expect(raw, isNot(contains('tool_result')));
    expect(raw, isNot(contains('arguments')));
    expect(raw, contains('最终回答'));
  });

  test('历史限制为最近十轮和总字符上限', () async {
    final secure = _MemoryPersonalConversationSecureStore();
    final store = PersonalConversationStore(
      accountKey: 'app-a::edu-a',
      blobStore: secure,
    );
    await store.replace(List<PersonalConversationEntry>.generate(
      30,
      (index) => _entry('message-$index', AiMessageRole.user),
    ));

    final restored = await store.read();
    expect(restored, hasLength(PersonalConversationStore.maximumMessages));
    expect(restored.first.message.content, 'message-10');
  });

  test('单条坏记录不会让整段历史读成空', () async {
    // 回归：role/status/created_at 曾在 fromJson 里裸奔（无 orElse、非 tryParse），
    // read() 的整段 try/catch 会把整份历史读成空，随后的 replace() 还会用
    // 空列表覆盖存档，不可恢复。
    final secure = _MemoryPersonalConversationSecureStore();
    final store = PersonalConversationStore(
      accountKey: 'app-a::edu-a',
      blobStore: secure,
    );
    await store.replace(<PersonalConversationEntry>[
      _entry('保留一', AiMessageRole.user),
      _entry('保留二', AiMessageRole.assistant),
    ]);

    // 模拟降级运行 + 单条被截断：未知枚举值、坏时间戳、缺 id/content。
    final key = secure.values.keys.single;
    final payload = jsonDecode(secure.values[key]!) as Map<String, dynamic>;
    final entries = payload['entries'] as List<dynamic>;
    (entries.first as Map<String, dynamic>)
      ..['role'] = 'tool'
      ..['status'] = 'streaming_v2'
      ..['created_at'] = 'not-a-timestamp';
    entries.add(<String, dynamic>{'role': 'user', 'content': '截断记录'});
    secure.values[key] = jsonEncode(payload);

    final restored = await store.read();

    expect(restored, hasLength(2), reason: '坏记录应被逐条跳过，其余历史必须保留');
    expect(restored.first.message.content, '保留一');
    expect(restored.first.message.role, AiMessageRole.assistant,
        reason: '未知枚举值应退到兜底值而不是抛异常');
    expect(restored.last.message.content, '保留二');
  });
}

PersonalConversationEntry _entry(
  String content,
  AiMessageRole role, {
  List<SkillEvidence> evidence = const <SkillEvidence>[],
}) =>
    PersonalConversationEntry(
      message: AiChatMessage(
        id: '$role-$content',
        requestId: content,
        role: role,
        content: content,
        status: AiMessageStatus.completed,
        createdAt: DateTime.utc(2026, 7, 21),
      ),
      evidence: evidence,
    );

class _MemoryPersonalConversationSecureStore implements AppBlobStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
