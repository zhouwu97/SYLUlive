/// 进入校园 Agent 时携带的最小业务上下文。
///
/// 客户端只发送实体类型和 ID，不把页面对象或整页 JSON 放入提示词。
/// 服务端会基于当前用户权限重新读取并校验这些引用。
class AgentContextRef {
  const AgentContextRef({required this.type, required this.id});

  final String type;
  final String id;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'id': id,
      };
}

class AgentLaunchContext {
  const AgentLaunchContext({
    required this.entrypoint,
    required this.contextRefs,
    this.suggestedIntent,
  });

  final String entrypoint;
  final List<AgentContextRef> contextRefs;
  final String? suggestedIntent;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'entrypoint': entrypoint,
        'context_refs': contextRefs.map((ref) => ref.toJson()).toList(),
        if (suggestedIntent?.trim().isNotEmpty == true)
          'suggested_intent': suggestedIntent!.trim(),
      };

  AgentLaunchContext copyWith({
    String? entrypoint,
    List<AgentContextRef>? contextRefs,
    String? suggestedIntent,
  }) {
    return AgentLaunchContext(
      entrypoint: entrypoint ?? this.entrypoint,
      contextRefs: contextRefs ?? this.contextRefs,
      suggestedIntent: suggestedIntent ?? this.suggestedIntent,
    );
  }
}
