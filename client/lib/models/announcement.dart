class Announcement {
  final int id;
  final String title;
  final String content;
  final int createdBy; // was authorId — backward compat: parsed from created_by or author_id
  final Map<String, dynamic>? creator;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isPinned;
  final String priority; // now String (urgent/important/normal), was int
  final String status;
  final String displayMode;
  final DateTime? publishAt;
  final DateTime? expiresAt;
  final bool includeNewUsers;

  Announcement({
    required this.id,
    required this.title,
    required this.content,
    required this.createdBy,
    this.creator,
    required this.createdAt,
    this.updatedAt,
    this.isPinned = false,
    this.priority = 'normal',
    this.status = 'published',
    this.displayMode = 'center',
    this.publishAt,
    this.expiresAt,
    this.includeNewUsers = false,
  });

  factory Announcement.fromJson(Map<String, dynamic> json) {
    return Announcement(
      id: json['id'] ?? 0,
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      // Backward compat: parse both created_by (new) and author_id (old)
      createdBy: json['created_by'] ?? json['author_id'] ?? 0,
      creator: json['creator'] is Map
          ? Map<String, dynamic>.from(json['creator'])
          : null,
      createdAt:
          DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'])
          : null,
      isPinned: json['is_pinned'] ?? false,
      // Backward compat: parse String (new), int (old), or default
      priority: _parsePriority(json['priority']),
      status: json['status'] ?? 'published',
      displayMode: json['display_mode'] ?? 'center',
      publishAt: json['publish_at'] != null
          ? DateTime.tryParse(json['publish_at'])
          : null,
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'])
          : null,
      includeNewUsers: json['include_new_users'] ?? false,
    );
  }

  /// Parse priority from either new String format or old int format.
  static String _parsePriority(dynamic value) {
    if (value is String && value.isNotEmpty) return value;
    if (value is int) {
      switch (value) {
        case 2:
          return 'urgent';
        case 1:
          return 'important';
        default:
          return 'normal';
      }
    }
    return 'normal';
  }

  /// Whether this announcement should trigger a modal popup on the home screen.
  bool get isModalUrgent =>
      (priority == 'urgent' || priority == 'important') &&
      (displayMode == 'modal' || displayMode.isEmpty);
}
