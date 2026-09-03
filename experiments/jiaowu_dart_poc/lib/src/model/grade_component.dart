/// 成绩构成分项。
///
/// 对应 Python 端的 GradeComponent。
final class GradeComponent {
  GradeComponent({
    required this.name,
    required this.score,
    this.weight,
  });

  /// 分项名称，如"平时"、"期末"、"总评"。
  final String name;

  /// 分项占比/权重，如"15%"、"60%"。
  ///
  /// 可能为 null（总评通常没有比例）。
  final String? weight;

  /// 分项成绩，如"98"、"60.1"。
  final String score;

  Map<String, Object?> toJson() => {
        'name': name,
        'weight': weight,
        'score': score,
      };

  @override
  String toString() =>
      'GradeComponent(name: $name, weight: $weight, score: $score)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GradeComponent &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          weight == other.weight &&
          score == other.score;

  @override
  int get hashCode => Object.hash(name, weight, score);
}
