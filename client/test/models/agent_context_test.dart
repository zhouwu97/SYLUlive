import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/agent_context.dart';

void main() {
  test('只序列化 Agent context 引用，不携带实体对象', () {
    const context = AgentLaunchContext(
      entrypoint: 'competition_detail',
      contextRefs: <AgentContextRef>[
        AgentContextRef(type: 'competition_event', id: '123'),
      ],
      suggestedIntent: '我适合参加这个比赛吗？',
    );

    expect(context.toJson(), <String, dynamic>{
      'entrypoint': 'competition_detail',
      'context_refs': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'competition_event', 'id': '123'},
      ],
      'suggested_intent': '我适合参加这个比赛吗？',
    });
    expect(context.toJson().containsKey('title'), isFalse);
  });
}
