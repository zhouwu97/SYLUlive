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
    this.sourceChannel = '',
    this.location = '',
    this.isOnline = false,
    this.officialUrl = '',
    this.noticeUrl = '',
    this.description = '',
  });

  factory CompetitionEvent.fromJson(Map<String, dynamic> json) {
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
      sourceChannel: json['source_channel'] ?? '',
      location: json['location'] ?? '',
      isOnline: json['is_online'] == true,
      officialUrl: json['official_url'] ?? '',
      noticeUrl: json['notice_url'] ?? '',
      description: json['description'] ?? '',
    );
  }
}
