class PollVisibility {
  const PollVisibility._();

  static const always = 'always';
  static const afterEnd = 'after_end';
  static const private = 'private';

  static const createOptions = <PollVisibilityOption>[
    PollVisibilityOption(
      value: always,
      title: '实时公开结果',
      description: '所有人可实时查看票数和比例',
    ),
    PollVisibilityOption(
      value: afterEnd,
      title: '结束后公开结果',
      description: '投票期间仅显示参与状态',
    ),
    PollVisibilityOption(
      value: private,
      title: '仅作者查看',
      description: '投票结果始终只对创建者可见',
    ),
  ];
}

class PollVisibilityOption {
  const PollVisibilityOption({
    required this.value,
    required this.title,
    required this.description,
  });

  final String value;
  final String title;
  final String description;
}
