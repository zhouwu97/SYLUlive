/// 服务端已持久化的话题。
class Topic {
  final int id;
  final String name;

  const Topic({required this.id, required this.name});

  factory Topic.fromJson(Map<String, dynamic> json) => Topic(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

/// Composer 中的选择项。自定义话题在帖子提交成功前不创建数据库记录。
class TopicSelection {
  final int? id;
  final String name;

  const TopicSelection({this.id, required this.name});

  const TopicSelection.existing({required int id, required String name})
      : id = id,
        name = name;

  const TopicSelection.custom(String name)
      : id = null,
        name = name;

  bool get isCustom => id == null;

  Map<String, dynamic> toJson() => isCustom ? {'name': name} : {'id': id};
}
