class ErkeSummary {
  final double categoryA;
  final double categoryB;
  final double categoryC;
  final double categoryD;
  final double categoryE;
  final double total;

  const ErkeSummary({
    required this.categoryA,
    required this.categoryB,
    required this.categoryC,
    required this.categoryD,
    required this.categoryE,
    required this.total,
  });

  factory ErkeSummary.fromJson(Map<String, dynamic> json) {
    return ErkeSummary(
      categoryA: (json['categoryA'] as num).toDouble(),
      categoryB: (json['categoryB'] as num).toDouble(),
      categoryC: (json['categoryC'] as num).toDouble(),
      categoryD: (json['categoryD'] as num).toDouble(),
      categoryE: (json['categoryE'] as num).toDouble(),
      total: (json['total'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'categoryA': categoryA,
        'categoryB': categoryB,
        'categoryC': categoryC,
        'categoryD': categoryD,
        'categoryE': categoryE,
        'total': total,
      };
}

class ErkeActivity {
  final String name;
  final String organizer;
  final String date;
  final String category;
  final String role;
  final int participantCount;
  final double score;

  const ErkeActivity({
    required this.name,
    required this.organizer,
    required this.date,
    required this.category,
    required this.role,
    required this.participantCount,
    required this.score,
  });

  factory ErkeActivity.fromJson(Map<String, dynamic> json) {
    return ErkeActivity(
      name: json['name'] as String,
      organizer: json['organizer'] as String,
      date: json['date'] as String,
      category: json['category'] as String,
      role: json['role'] as String,
      participantCount: json['participantCount'] as int,
      score: (json['score'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'organizer': organizer,
        'date': date,
        'category': category,
        'role': role,
        'participantCount': participantCount,
        'score': score,
      };
}

class ErkeActivitiesPage {
  final List<ErkeActivity> activities;
  final bool hasNext;
  final String? nextViewState;

  const ErkeActivitiesPage({
    required this.activities,
    required this.hasNext,
    this.nextViewState,
  });
}
