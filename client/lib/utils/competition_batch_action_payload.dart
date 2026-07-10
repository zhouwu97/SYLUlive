Map<String, dynamic> buildCompetitionCalendarBatchActionPayload({
  required Iterable<int> ids,
  required String action,
}) {
  final actionPayload = switch (action) {
    'watching' => <String, dynamic>{'action': 'restore'},
    'preparing' ||
    'registered' ||
    'submitted' ||
    'finished' =>
      <String, dynamic>{
        'action': 'set_plan_status',
        'plan_status': action,
      },
    'archived' => <String, dynamic>{'action': 'archive'},
    'delete' => <String, dynamic>{'action': 'delete'},
    _ => throw ArgumentError.value(
        action,
        'action',
        '不支持的竞赛计划批量操作',
      ),
  };

  return <String, dynamic>{
    'ids': ids.toSet().toList(growable: false),
    ...actionPayload,
  };
}
