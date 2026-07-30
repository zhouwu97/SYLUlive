class PollOption {
  final int id;
  final String text;
  final int sortOrder;
  final int? voteCount;
  final double? ratio;
  final bool isChosen;

  const PollOption({
    required this.id,
    required this.text,
    required this.sortOrder,
    this.voteCount,
    this.ratio,
    this.isChosen = false,
  });

  factory PollOption.fromJson(Map<String, dynamic> json) {
    return PollOption(
      id: (json['id'] as num?)?.toInt() ?? 0,
      text: json['text']?.toString() ?? '',
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      voteCount: (json['vote_count'] as num?)?.toInt(),
      ratio: (json['ratio'] as num?)?.toDouble(),
      isChosen: json['is_chosen'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'sort_order': sortOrder,
        if (voteCount != null) 'vote_count': voteCount,
        if (ratio != null) 'ratio': ratio,
        'is_chosen': isChosen,
      };
}

class PollMeta {
  final int id;
  final int postId;
  final String category;
  final String selectionMode;
  final int maxChoices;
  final String resultsVisibility;
  final bool allowChange;
  final String status;
  final String effectiveStatus;
  final DateTime endsAt;
  final int remainingSeconds;
  final int participantCount;
  final int? choiceCount;
  final bool hasVoted;
  final bool resultsVisible;
  final bool canVote;
  final bool canChange;
  final bool isOwner;
  final List<PollOption> options;

  const PollMeta({
    required this.id,
    required this.postId,
    required this.category,
    required this.selectionMode,
    required this.maxChoices,
    required this.resultsVisibility,
    required this.allowChange,
    required this.status,
    required this.effectiveStatus,
    required this.endsAt,
    required this.remainingSeconds,
    required this.participantCount,
    this.choiceCount,
    required this.hasVoted,
    required this.resultsVisible,
    required this.canVote,
    required this.canChange,
    required this.isOwner,
    required this.options,
  });

  bool get isActive => effectiveStatus == 'active';
  bool get isClosed => effectiveStatus == 'closed';
  bool get isMultiple => selectionMode == 'multiple';
  List<int> get chosenOptionIds => options
      .where((option) => option.isChosen)
      .map((option) => option.id)
      .toList();

  factory PollMeta.fromJson(Map<String, dynamic> json) {
    return PollMeta(
      id: (json['id'] as num?)?.toInt() ?? 0,
      postId: (json['post_id'] as num?)?.toInt() ?? 0,
      category: json['category']?.toString() ?? 'other',
      selectionMode: json['selection_mode']?.toString() ?? 'single',
      maxChoices: (json['max_choices'] as num?)?.toInt() ?? 1,
      resultsVisibility: json['results_visibility']?.toString() ?? 'always',
      allowChange: json['allow_change'] == true,
      status: json['status']?.toString() ?? 'active',
      effectiveStatus: json['effective_status']?.toString() ?? 'active',
      endsAt: DateTime.tryParse(json['ends_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      remainingSeconds: (json['remaining_seconds'] as num?)?.toInt() ?? 0,
      participantCount: (json['participant_count'] as num?)?.toInt() ?? 0,
      choiceCount: (json['choice_count'] as num?)?.toInt(),
      hasVoted: json['has_voted'] == true,
      resultsVisible:
          json['can_view_result'] == true || json['results_visible'] == true,
      canVote: json['can_vote'] == true,
      canChange: json['can_change'] == true,
      isOwner: json['is_owner'] == true,
      options: (json['options'] as List<dynamic>? ?? const [])
          .map((item) => PollOption.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'post_id': postId,
        'category': category,
        'selection_mode': selectionMode,
        'max_choices': maxChoices,
        'results_visibility': resultsVisibility,
        'allow_change': allowChange,
        'status': status,
        'effective_status': effectiveStatus,
        'ends_at': endsAt.toUtc().toIso8601String(),
        'remaining_seconds': remainingSeconds,
        'participant_count': participantCount,
        if (choiceCount != null) 'choice_count': choiceCount,
        'has_voted': hasVoted,
        'results_visible': resultsVisible,
        'can_vote': canVote,
        'can_change': canChange,
        'is_owner': isOwner,
        'options': options.map((option) => option.toJson()).toList(),
      };
}
