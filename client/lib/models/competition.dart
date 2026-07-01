class CompetitionCategory {
  final int id;
  final String name;
  final String slug;
  final String icon;

  CompetitionCategory({
    required this.id,
    required this.name,
    required this.slug,
    this.icon = '',
  });

  factory CompetitionCategory.fromJson(Map<String, dynamic> json) {
    return CompetitionCategory(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      slug: json['slug'] ?? '',
      icon: json['icon'] ?? '',
    );
  }
}

class CompetitionEvent {
  final int id;
  final String title;
  final String summary;
  final CompetitionCategory? primaryCategory;
  final String competitionLevel;
  final String schoolRecognitionStatus;
  final String schoolRecognitionGrade;
  final String recommendationLevel;
  final int importanceScore;
  final String recommendationReason;
  final String organizer;
  final String registrationTimeText;
  final String eventTimeText;
  final DateTime? registrationEnd;
  final DateTime? eventStart;
  final String timePrecision;
  final String timeStatus;
  final String timeNote;
  final int sortMonth;
  final bool hasTimeStatus;
  final String sourceChannel;
  final String location;
  final bool isOnline;
  final String officialUrl;
  final String noticeUrl;
  final String description;

  CompetitionEvent({
    required this.id,
    required this.title,
    this.summary = '',
    this.primaryCategory,
    this.competitionLevel = '',
    this.schoolRecognitionStatus = '',
    this.schoolRecognitionGrade = '',
    this.recommendationLevel = '',
    this.importanceScore = 0,
    this.recommendationReason = '',
    this.organizer = '',
    this.registrationTimeText = '',
    this.eventTimeText = '',
    this.registrationEnd,
    this.eventStart,
    this.timePrecision = 'unknown',
    this.timeStatus = 'pending',
    this.timeNote = '',
    this.sortMonth = 0,
    this.hasTimeStatus = false,
    this.sourceChannel = '',
    this.location = '',
    this.isOnline = false,
    this.officialUrl = '',
    this.noticeUrl = '',
    this.description = '',
  });

  factory CompetitionEvent.fromJson(Map<String, dynamic> json) {
    final rawTimeStatus = json['time_status'];
    return CompetitionEvent(
      id: json['id'] ?? 0,
      title: json['title'] ?? '',
      summary: json['summary'] ?? '',
      primaryCategory: json['primary_category'] != null
          ? CompetitionCategory.fromJson(json['primary_category'])
          : null,
      competitionLevel: json['competition_level'] ?? '',
      schoolRecognitionStatus: json['school_recognition_status'] ?? '',
      schoolRecognitionGrade: json['school_recognition_grade'] ?? '',
      recommendationLevel: json['recommendation_level'] ?? '',
      importanceScore: json['importance_score'] ?? 0,
      recommendationReason: json['recommendation_reason'] ?? '',
      organizer: json['organizer'] ?? '',
      registrationTimeText: json['registration_time_text'] ?? '',
      eventTimeText: json['event_time_text'] ?? '',
      registrationEnd: DateTime.tryParse(json['registration_end'] ?? ''),
      eventStart: DateTime.tryParse(json['event_start'] ?? ''),
      timePrecision: json['time_precision'] ?? 'unknown',
      timeStatus: rawTimeStatus ?? 'pending',
      timeNote: json['time_note'] ?? '',
      sortMonth: (json['sort_month'] as num?)?.toInt() ?? 0,
      hasTimeStatus: json.containsKey('time_status') &&
          '${rawTimeStatus ?? ''}'.trim().isNotEmpty,
      sourceChannel: json['source_channel'] ?? '',
      location: json['location'] ?? '',
      isOnline: json['is_online'] == true,
      officialUrl: json['official_url'] ?? '',
      noticeUrl: json['notice_url'] ?? '',
      description: json['description'] ?? '',
    );
  }

  bool get hasExactDeadline => registrationEnd != null;

  bool get isTimeConfirmed => timeStatus == 'confirmed';

  String get timeStatusLabel {
    switch (timeStatus) {
      case 'confirmed':
        return '已确认';
      case 'estimated':
        return '预计时间';
      case 'historical':
        return '往年参考';
      default:
        return '待通知';
    }
  }

  String get timePrecisionLabel {
    switch (timePrecision) {
      case 'exact':
        return '精确到日';
      case 'month':
        return '按月份';
      case 'month_range':
        return '月份范围';
      case 'quarter':
        return '季度';
      case 'half_year':
        return '半年';
      case 'season':
        return '季节';
      default:
        return '不确定';
    }
  }

  String get displayTimeText {
    if (registrationEnd != null) {
      final dt = registrationEnd!;
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }
    if (registrationTimeText.trim().isNotEmpty) {
      return registrationTimeText.trim();
    }
    if (eventTimeText.trim().isNotEmpty) {
      return eventTimeText.trim();
    }
    if (sortMonth >= 1 && sortMonth <= 12) {
      return '$sortMonth 月左右';
    }
    return '时间待通知';
  }
}
