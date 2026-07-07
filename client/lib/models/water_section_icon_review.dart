class WaterSectionIconReview {
  final int id;
  final int sectionId;
  final String sectionTitle;
  final int requestedBy;
  final String? requesterName;
  final String oldAvatarUrl;
  final String newAvatarUrl;
  final String reason;
  final String status;
  final int? reviewedBy;
  final String? reviewerName;
  final DateTime? reviewedAt;
  final String reviewReason;
  final DateTime createdAt;

  const WaterSectionIconReview({
    required this.id,
    required this.sectionId,
    required this.sectionTitle,
    required this.requestedBy,
    this.requesterName,
    required this.oldAvatarUrl,
    required this.newAvatarUrl,
    required this.reason,
    required this.status,
    this.reviewedBy,
    this.reviewerName,
    this.reviewedAt,
    required this.reviewReason,
    required this.createdAt,
  });

  factory WaterSectionIconReview.fromJson(Map<String, dynamic> json) {
    return WaterSectionIconReview(
      id: json['id'] as int? ?? 0,
      sectionId: json['section_id'] as int? ?? 0,
      sectionTitle: json['section_title'] as String? ?? '',
      requestedBy: json['requested_by'] as int? ?? 0,
      requesterName: json['requester_name'] as String?,
      oldAvatarUrl: json['old_avatar_url'] as String? ?? '',
      newAvatarUrl: json['new_avatar_url'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      reviewedBy: json['reviewed_by'] as int?,
      reviewerName: json['reviewer_name'] as String?,
      reviewedAt: json['reviewed_at'] != null
          ? DateTime.parse(json['reviewed_at'])
          : null,
      reviewReason: json['review_reason'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : DateTime.now(),
    );
  }
}

class WaterSectionIconReviewState {
  final WaterSectionIconReview? pending;
  final WaterSectionIconReview? latest;

  const WaterSectionIconReviewState({this.pending, this.latest});

  factory WaterSectionIconReviewState.fromJson(Map<String, dynamic> json) {
    return WaterSectionIconReviewState(
      pending: json['pending'] != null
          ? WaterSectionIconReview.fromJson(json['pending'])
          : null,
      latest: json['latest'] != null
          ? WaterSectionIconReview.fromJson(json['latest'])
          : null,
    );
  }
}
