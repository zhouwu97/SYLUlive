class Teacher {
  final int id;
  final String name;
  final String course;
  final int ratingCount;
  final double averageStar;
  final DateTime createdAt;

  Teacher({
    required this.id,
    required this.name,
    required this.course,
    this.ratingCount = 0,
    this.averageStar = 0,
    required this.createdAt,
  });

  factory Teacher.fromJson(Map<String, dynamic> json) {
    return Teacher(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      course: json['course'] ?? '',
      ratingCount: json['rating_count'] ?? 0,
      averageStar: (json['average_star'] ?? 0).toDouble(),
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}

class TeacherRating {
  final int id;
  final int teacherId;
  final int userId;
  final int star;
  final String comment;
  final String userName;
  final String userStudentId;
  final DateTime createdAt;

  TeacherRating({
    required this.id,
    required this.teacherId,
    required this.userId,
    required this.star,
    required this.comment,
    this.userName = '',
    this.userStudentId = '',
    required this.createdAt,
  });

  factory TeacherRating.fromJson(Map<String, dynamic> json) {
    return TeacherRating(
      id: json['id'] ?? 0,
      teacherId: json['teacher_id'] ?? 0,
      userId: json['user_id'] ?? 0,
      star: json['star'] ?? 0,
      comment: json['comment'] ?? '',
      userName: json['user_name'] ?? '',
      userStudentId: json['user_student_id'] ?? '',
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
