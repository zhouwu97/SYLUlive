enum CourseNature { requiredCourse, elective, other }

enum CourseAttemptType { normal, makeup, retake }

class CourseGradeRecord {
  const CourseGradeRecord({
    required this.courseId,
    required this.courseName,
    required this.credit,
    required this.nature,
    required this.attemptType,
    required this.semesterId,
    this.score,
    this.gradeText,
  });

  final String courseId;
  final String courseName;
  final double? score;
  final String? gradeText;
  final double credit;
  final CourseNature nature;
  final CourseAttemptType attemptType;
  final String semesterId;
}

class AcademicRecords {
  AcademicRecords({required List<CourseGradeRecord> courses})
      : courses = List<CourseGradeRecord>.unmodifiable(courses);

  final List<CourseGradeRecord> courses;
}
