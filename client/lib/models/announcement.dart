class Announcement {
  final int id;
  final String title;
  final String content;
  final int authorId;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isPinned;
  final int priority;

  Announcement({
    required this.id,
    required this.title,
    required this.content,
    required this.authorId,
    required this.createdAt,
    this.updatedAt,
    this.isPinned = false,
    this.priority = 0,
  });

  factory Announcement.fromJson(Map<String, dynamic> json) {
    return Announcement(
      id: json['id'] ?? 0,
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      authorId: json['author_id'] ?? 0,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'])
          : null,
      isPinned: json['is_pinned'] ?? false,
      priority: json['priority'] ?? 0,
    );
  }
}
