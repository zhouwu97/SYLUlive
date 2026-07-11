class ExamPaperContributor {
  final int id;
  final String avatar;
  final String nickname;
  final int level;

  const ExamPaperContributor({
    required this.id,
    required this.avatar,
    required this.nickname,
    required this.level,
  });

  factory ExamPaperContributor.fromJson(Map<String, dynamic> json) {
    return ExamPaperContributor(
      id: (json['id'] as num?)?.toInt() ?? 0,
      avatar: json['avatar']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '匿名同学',
      level: (json['level'] as num?)?.toInt() ?? 1,
    );
  }
}

class ExamPaper {
  final int id;
  final String status;
  final String source;
  final String courseName;
  final String academicYear;
  final String semester;
  final String examType;
  final String title;
  final int fileSize;
  final int downloadCount;
  final String approvalReason;
  final String unpublishReason;
  final DateTime? publishedAt;
  final DateTime? unpublishedAt;
  final DateTime createdAt;
  final ExamPaperContributor contributor;

  const ExamPaper({
    required this.id,
    required this.status,
    required this.source,
    required this.courseName,
    required this.academicYear,
    required this.semester,
    required this.examType,
    required this.title,
    required this.fileSize,
    required this.downloadCount,
    required this.approvalReason,
    required this.unpublishReason,
    required this.publishedAt,
    required this.unpublishedAt,
    required this.createdAt,
    required this.contributor,
  });

  factory ExamPaper.fromJson(Map<String, dynamic> json) {
    final contributorJson = json['contributor'];
    return ExamPaper(
      id: (json['id'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      courseName: json['course_name']?.toString() ?? '',
      academicYear: json['academic_year']?.toString() ?? '',
      semester: json['semester']?.toString() ?? '',
      examType: json['exam_type']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
      downloadCount: (json['download_count'] as num?)?.toInt() ?? 0,
      approvalReason: json['approval_reason']?.toString() ?? '',
      unpublishReason: json['unpublish_reason']?.toString() ?? '',
      publishedAt: _parseTime(json['published_at']),
      unpublishedAt: _parseTime(json['unpublished_at']),
      createdAt: _parseTime(json['created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      contributor: ExamPaperContributor.fromJson(
        contributorJson is Map<String, dynamic>
            ? contributorJson
            : const <String, dynamic>{},
      ),
    );
  }

  static DateTime? _parseTime(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  bool get isPending => status == 'pending';
  bool get isPublished => status == 'published';
  bool get isUnpublished => status == 'unpublished';
  bool get isAdminUpload => source == 'admin';

  String get statusLabel {
    switch (status) {
      case 'pending':
        return '待审核';
      case 'published':
        return '已通过';
      case 'unpublished':
        return '已下架';
      default:
        return status;
    }
  }

  String get semesterLabel =>
      ExamPaperMetadata.semesterLabels[semester] ?? semester;

  String get examTypeLabel =>
      ExamPaperMetadata.examTypeLabels[examType] ?? examType;

  String get fileSizeLabel {
    if (fileSize >= 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (fileSize >= 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    return '$fileSize B';
  }
}

class ExamPaperPage {
  final List<ExamPaper> items;
  final int page;
  final int pageSize;
  final int total;

  /// 各状态的全量计数；普通列表接口未返回时为空。
  final Map<String, int> statusCounts;

  const ExamPaperPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
    this.statusCounts = const {},
  });

  factory ExamPaperPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return ExamPaperPage(
      items: rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((item) => ExamPaper.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList(growable: false)
          : const [],
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['page_size'] as num?)?.toInt() ?? 20,
      total: (json['total'] as num?)?.toInt() ?? 0,
      statusCounts: _parseStatusCounts(json['status_counts']),
    );
  }

  static Map<String, int> _parseStatusCounts(dynamic value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
    };
  }

  bool get hasMore => page * pageSize < total;
}

class ExamPaperMetadata {
  static const Map<String, String> semesterLabels = {
    'first': '第一学期',
    'second': '第二学期',
    'other': '其他',
  };

  static const Map<String, String> examTypeLabels = {
    'midterm': '期中',
    'final': '期末',
    'makeup': '补考',
    'retake': '重修',
    'other': '其他',
  };

  static List<String> academicYears(DateTime now) {
    final latestStartYear = now.month >= 9 ? now.year : now.year - 1;
    return [
      for (var year = latestStartYear; year >= 2000; year--)
        '$year-${year + 1}',
    ];
  }

  static String buildTitle({
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
  }) {
    final normalizedCourse = courseName.trim();
    final semesterLabel = semesterLabels[semester] ?? semester;
    final examTypeLabel = examTypeLabels[examType] ?? examType;
    return '$normalizedCourse · $academicYear · $semesterLabel · $examTypeLabel';
  }
}
