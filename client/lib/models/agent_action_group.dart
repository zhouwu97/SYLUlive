enum AgentActionGroupStatus {
  proposed,
  waitingConfirmation,
  executing,
  partiallyCompleted,
  completed,
  failed,
  cancelled,
}

class AgentActionItem {
  const AgentActionItem({
    required this.actionType,
    required this.title,
    this.status = AgentActionGroupStatus.proposed,
    this.referenceId,
  });

  final String actionType;
  final String title;
  final AgentActionGroupStatus status;
  final String? referenceId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'action_type': actionType,
        'title': title,
        'status': status.name,
        if (referenceId != null) 'reference_id': referenceId,
      };
}

class AgentActionGroup {
  const AgentActionGroup({
    required this.runId,
    required this.title,
    required this.status,
    required this.actions,
  });

  final String runId;
  final String title;
  final AgentActionGroupStatus status;
  final List<AgentActionItem> actions;

  bool get needsConfirmation =>
      status == AgentActionGroupStatus.proposed ||
      status == AgentActionGroupStatus.waitingConfirmation;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'run_id': runId,
        'title': title,
        'status': status.name,
        'actions': actions.map((action) => action.toJson()).toList(),
      };
}
