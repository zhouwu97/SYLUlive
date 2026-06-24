/// Data models for the teaching evaluation assistant.
library;

/// Page type classification from probe results.
enum EvaluationPageType {
  loading,
  login,
  courseList,
  evaluationForm,
  submitted,
  sessionExpired,
  accessDenied,
  unknown,
}

/// Where the score range was found.
enum ScoreRangeSource {
  minMax,
  dataAttr,
  placeholder,
  text,
}

/// Describes a numeric score input (text or number type).
class ScoreInput {
  final String? id;
  final String? name;
  final String? className;
  final String? type;
  final String? placeholder;
  final bool disabled;
  final bool readOnly;
  final bool isVisible;
  final String? framePath;
  
  final double? minScore;
  final double? maxScore;
  final ScoreRangeSource? rangeSource;
  final bool rangeIsAmbiguous;
  final bool isOptionalComment;
  final String? skipReason;

  const ScoreInput({
    this.id,
    this.name,
    this.className,
    this.type,
    this.placeholder,
    this.disabled = false,
    this.readOnly = false,
    this.isVisible = true,
    this.framePath,
    this.minScore,
    this.maxScore,
    this.rangeSource,
    this.rangeIsAmbiguous = false,
    this.isOptionalComment = false,
    this.skipReason,
  });

  factory ScoreInput.fromJson(Map<String, dynamic> json) {
    ScoreRangeSource? src;
    if (json['rangeSource'] != null) {
      switch (json['rangeSource']) {
        case 'minMax': src = ScoreRangeSource.minMax; break;
        case 'dataAttr': src = ScoreRangeSource.dataAttr; break;
        case 'placeholder': src = ScoreRangeSource.placeholder; break;
        case 'text': src = ScoreRangeSource.text; break;
      }
    }
    return ScoreInput(
      id: json['id'] as String?,
      name: json['name'] as String?,
      className: json['className'] as String?,
      type: json['type'] as String?,
      placeholder: json['placeholder'] as String?,
      disabled: json['disabled'] == true,
      readOnly: json['readOnly'] == true,
      isVisible: json['isVisible'] != false, // Default true if omitted
      framePath: json['framePath'] as String?,
      minScore: (json['minScore'] as num?)?.toDouble(),
      maxScore: (json['maxScore'] as num?)?.toDouble(),
      rangeSource: src,
      rangeIsAmbiguous: json['rangeIsAmbiguous'] == true,
      isOptionalComment: json['isOptionalComment'] == true,
      skipReason: json['skipReason'] as String?,
    );
  }

  bool get isReliableScore =>
      !disabled &&
      !readOnly &&
      isVisible &&
      !isOptionalComment &&
      !rangeIsAmbiguous &&
      minScore != null &&
      maxScore != null &&
      maxScore! > minScore!;
}

/// Describes one radio button option collected by the probe script.
class RadioOption {
  final String? name;
  final String? id;
  final String? value;
  final String? className;
  final String? dataDyf;
  final String? dataScore;
  final String? dataFz;
  final bool checked;
  final bool disabled;

  const RadioOption({
    this.name,
    this.id,
    this.value,
    this.className,
    this.dataDyf,
    this.dataScore,
    this.dataFz,
    this.checked = false,
    this.disabled = false,
  });

  factory RadioOption.fromJson(Map<String, dynamic> json) {
    return RadioOption(
      name: json['name'] as String?,
      id: json['id'] as String?,
      value: json['value'] as String?,
      className: json['className'] as String?,
      dataDyf: json['data_dyf'] as String?,
      dataScore: json['data_score'] as String?,
      dataFz: json['data_fz'] as String?,
      checked: json['checked'] == true,
      disabled: json['disabled'] == true,
    );
  }
}

/// A group of radio inputs sharing the same name.
class RadioGroup {
  final String name;
  final List<RadioOption> options;

  const RadioGroup({required this.name, required this.options});

  /// Highest numeric score found among enabled options, or null.
  double? get bestScore {
    double? best;
    for (final o in options) {
      if (o.disabled) continue;
      final s = _extractScore(o);
      if (s != null && (best == null || s > best)) best = s;
    }
    return best;
  }

  /// Option with the highest score, or null if none scoreable.
  RadioOption? get bestOption {
    RadioOption? best;
    double? bestScore;
    for (final o in options) {
      if (o.disabled) continue;
      final s = _extractScore(o);
      if (s != null && (bestScore == null || s > bestScore)) {
        bestScore = s;
        best = o;
      }
    }
    return best;
  }

  bool get isAlreadyCompleted => options.any((o) => o.checked && !o.disabled);

  /// Whether any option has a recognizable score attribute (data-dyf/data-score/data-fz only).
  bool get hasScoreAttribute => options.any(
    (o) => o.dataDyf != null || o.dataScore != null || o.dataFz != null,
  );

  /// Extract numeric score using ONLY explicit score attributes.
  /// Never uses radio.value as a score.
  static double? _extractScore(RadioOption o) {
    final candidates = [o.dataDyf, o.dataScore, o.dataFz];
    for (final c in candidates) {
      final v = double.tryParse(c ?? '');
      if (v != null && v >= 0) return v;
    }
    return null;
  }

  static List<RadioGroup> fromOptionsList(List<RadioOption> allOptions) {
    final map = <String, List<RadioOption>>{};
    for (final o in allOptions) {
      final key = o.name ?? o.id ?? '';
      if (key.isEmpty) continue;
      map.putIfAbsent(key, () => []).add(o);
    }
    return map.entries
        .map((e) => RadioGroup(name: e.key, options: e.value))
        .toList();
  }
}

/// Result returned by the probe JavaScript.
class EvaluationProbeResult {
  final String url;
  final String title;
  final String pageTextSample;
  final int radioCount;
  final List<RadioOption> radioOptions;
  final List<ScoreInput> scoreInputs;
  final int textareaCount; // Legacy textarea count, kept for backwards compatibility or general stats
  final int optionalCommentCount;
  final List<Map<String, dynamic>> forms;
  final List<Map<String, dynamic>> buttons;
  final List<Map<String, dynamic>> possibleCourseRows;
  final bool hasLoginForm;
  final bool hasEvaluationForm;

  // Boolean text flags — set by JS after scanning full body text.
  final bool hasSubmittedText;
  final bool hasSessionExpiredText;
  final bool hasAccessDeniedText;
  final bool hasMaintenanceText;
  final bool hasAlreadyEvaluatedText;

  final String? error;

  const EvaluationProbeResult({
    required this.url,
    required this.title,
    required this.pageTextSample,
    required this.radioCount,
    required this.radioOptions,
    this.scoreInputs = const [],
    required this.textareaCount,
    this.optionalCommentCount = 0,
    required this.forms,
    required this.buttons,
    required this.possibleCourseRows,
    required this.hasLoginForm,
    required this.hasEvaluationForm,
    this.hasSubmittedText = false,
    this.hasSessionExpiredText = false,
    this.hasAccessDeniedText = false,
    this.hasMaintenanceText = false,
    this.hasAlreadyEvaluatedText = false,
    this.error,
  });

  factory EvaluationProbeResult.fromJson(Map<String, dynamic> json) {
    final radioRaw = json['radioOptions'] as List<dynamic>?;
    final scoreRaw = json['scoreInputs'] as List<dynamic>?;
    return EvaluationProbeResult(
      url: (json['url'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      pageTextSample: (json['pageTextSample'] as String?) ?? '',
      radioCount: (json['radioCount'] as int?) ?? 0,
      radioOptions:
          radioRaw
              ?.map((e) => RadioOption.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      scoreInputs:
          scoreRaw
              ?.map((e) => ScoreInput.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      textareaCount: (json['textareaCount'] as int?) ?? 0,
      optionalCommentCount: (json['optionalCommentCount'] as int?) ?? 0,
      forms: _listOfMaps(json['forms']),
      buttons: _listOfMaps(json['buttons']),
      possibleCourseRows: _listOfMaps(json['possibleCourseRows']),
      hasLoginForm: json['hasLoginForm'] == true,
      hasEvaluationForm: json['hasEvaluationForm'] == true,
      hasSubmittedText: json['hasSubmittedText'] == true,
      hasSessionExpiredText: json['hasSessionExpiredText'] == true,
      hasAccessDeniedText: json['hasAccessDeniedText'] == true,
      hasMaintenanceText: json['hasMaintenanceText'] == true,
      hasAlreadyEvaluatedText: json['hasAlreadyEvaluatedText'] == true,
      error: json['error'] as String?,
    );
  }

  static List<Map<String, dynamic>> _listOfMaps(dynamic src) {
    if (src is! List) return [];
    return src.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  List<RadioGroup> get radioGroups => RadioGroup.fromOptionsList(radioOptions);

  String get debugSummary =>
      'EvaluationProbeResult('
      'url=$url, title=$title, radioCount=$radioCount, '
      'textareaCount=$textareaCount, groups=${radioGroups.length}, '
      'hasLogin=$hasLoginForm, hasEval=$hasEvaluationForm, '
      'submitted=$hasSubmittedText, expired=$hasSessionExpiredText, '
      'denied=$hasAccessDeniedText, maint=$hasMaintenanceText'
      '${error != null ? ", error=$error" : ""})';
}

/// Result from the fill script execution.
class EvaluationFillResult {
  final int radioTotalGroups;
  final int radioCompletedGroups;
  final int scoreInputCount;
  final int scoreInputCompletedCount;
  final List<String> unresolvedRadioGroups;
  final List<String> unresolvedScoreInputs;
  final int optionalCommentCount;
  final List<String> warnings;
  final String? error;

  const EvaluationFillResult({
    this.radioTotalGroups = 0,
    this.radioCompletedGroups = 0,
    this.scoreInputCount = 0,
    this.scoreInputCompletedCount = 0,
    this.unresolvedRadioGroups = const [],
    this.unresolvedScoreInputs = const [],
    this.optionalCommentCount = 0,
    required this.warnings,
    this.error,
  });

  factory EvaluationFillResult.fromJson(Map<String, dynamic> json) {
    return EvaluationFillResult(
      radioTotalGroups: (json['radioTotalGroups'] as int?) ?? 0,
      radioCompletedGroups: (json['radioCompletedGroups'] as int?) ?? 0,
      scoreInputCount: (json['scoreInputCount'] as int?) ?? 0,
      scoreInputCompletedCount: (json['scoreInputCompletedCount'] as int?) ?? 0,
      unresolvedRadioGroups: _stringList(json['unresolvedRadioGroups']),
      unresolvedScoreInputs: _stringList(json['unresolvedScoreInputs']),
      optionalCommentCount: (json['optionalCommentCount'] as int?) ?? 0,
      warnings: _stringList(json['warnings']),
      error: json['error'] as String?,
    );
  }

  factory EvaluationFillResult.error(String message) {
    return EvaluationFillResult(
      warnings: [],
      error: message,
    );
  }

  bool get hasUnresolved => unresolvedRadioGroups.isNotEmpty || unresolvedScoreInputs.isNotEmpty;
  bool get hasRequiredTextareas => false; // Kept for backwards compat signature, but logic handled via warnings if needed
  bool get hasWarnings => warnings.isNotEmpty;
  bool get allCompleted => 
    (radioTotalGroups > 0 && radioCompletedGroups >= radioTotalGroups) ||
    (scoreInputCount > 0 && scoreInputCompletedCount >= scoreInputCount);

  static List<String> _stringList(dynamic src) {
    if (src is! List) return [];
    return src.map((e) => e.toString()).toList();
  }
}
