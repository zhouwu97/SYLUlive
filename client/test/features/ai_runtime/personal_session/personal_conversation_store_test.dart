import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/personal_session/personal_conversation_store.dart';
import 'package:shenliyuan/features/ai_runtime/skills/personal_skill.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';

void main() {
  test('个人历史按账号隔离并恢复证据摘要', () async {
    final secure = _MemoryConversationSecureStore();
    final accountA = PersonalConversationStore(
      accountKey: 'app-a::edu-a',
      secureStore: secure,
    );
    final accountB = PersonalConversationStore(
      accountKey: 'app-b::edu-b',
      secureStore: secure,
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
    final secure = _MemoryConversationSecureStore();
    final store = PersonalConversationStore(
      accountKey: 'app-a::edu-a',
      secureStore: secure,
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
    final secure = _MemoryConversationSecureStore();
    final store = PersonalConversationStore(
      accountKey: 'app-a::edu-a',
      secureStore: secure,
    );
    await store.replace(List<PersonalConversationEntry>.generate(
      30,
      (index) => _entry('message-$index', AiMessageRole.user),
    ));

    final restored = await store.read();
    expect(restored, hasLength(PersonalConversationStore.maximumMessages));
    expect(restored.first.message.content, 'message-10');
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

class _MemoryConversationSecureStore
    implements PersonalConversationSecureStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
