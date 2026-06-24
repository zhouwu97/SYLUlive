/// Data models for the teaching evaluation assistant.
///
/// These models represent the parsed results from the probe and fill scripts
/// injected into the教务 evaluation WebView.
library;

/// Page type classification from probe results.
enum EvaluationPageType {
  /// Still loading / no data yet
  loading,

  /// Login page detected
  login,

  /// Course list — multiple courses to evaluate
  courseList,

  /// Single course evaluation form
  evaluationForm,

  /// Submission success / thank-you page
  submitted,

  /// Session expired, needs re-login
  sessionExpired,

  /// Access denied / no permission
  accessDenied,

  /// Cannot determine page type
  unknown,
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

  Map<String, dynamic> toJson() => {
        'name': name,
        'id': id,
        'value': value,
        'className': className,
        'data_dyf': dataDyf,
        'data_score': dataScore,
        'data_fz': dataFz,
        'checked': checked,
        'disabled': disabled,
      };
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

  /// Whether this group is already fully completed (has a checked option).
  bool get isAlreadyCompleted => options.any((o) => o.checked && !o.disabled);

  /// Whether any option has a recognizable score attribute.
  bool get hasScoreAttribute => options.any(
        (o) =>
            o.dataDyf != null ||
            o.dataScore != null ||
            o.dataFz != null ||
            _valueIsNumericScore(o.value) != null,
      );

  /// Extract numeric score from a RadioOption using the priority chain.
  static double? _extractScore(RadioOption o) {
    final candidates = [o.dataDyf, o.dataScore, o.dataFz];
    for (final c in candidates) {
      final v = double.tryParse(c ?? '');
      if (v != null) return v;
    }
    // Fallback: value as numeric score (only if clearly numeric)
    return _valueIsNumericScore(o.value);
  }

  static double? _valueIsNumericScore(String? value) {
    if (value == null || value.isEmpty) return null;
    // Only accept values that are purely numeric and look like scores (1-100)
    final v = double.tryParse(value);
    if (v != null && v >= 0 && v <= 100) return v;
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
  final int textareaCount;
  final List<Map<String, dynamic>> forms;
  final List<Map<String, dynamic>> buttons;
  final List<Map<String, dynamic>> possibleCourseRows;
  final bool hasLoginForm;
  final bool hasEvaluationForm;
  final String? error;

  const EvaluationProbeResult({
    required this.url,
    required this.title,
    required this.pageTextSample,
    required this.radioCount,
    required this.radioOptions,
    required this.textareaCount,
    required this.forms,
    required this.buttons,
    required this.possibleCourseRows,
    required this.hasLoginForm,
    required this.hasEvaluationForm,
    this.error,
  });

  factory EvaluationProbeResult.fromJson(Map<String, dynamic> json) {
    final radioRaw = json['radioOptions'] as List<dynamic>?;
    return EvaluationProbeResult(
      url: (json['url'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      pageTextSample: (json['pageTextSample'] as String?) ?? '',
      radioCount: (json['radioCount'] as int?) ?? 0,
      radioOptions: radioRaw
              ?.map((e) => RadioOption.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      textareaCount: (json['textareaCount'] as int?) ?? 0,
      forms: _listOfMaps(json['forms']),
      buttons: _listOfMaps(json['buttons']),
      possibleCourseRows: _listOfMaps(json['possibleCourseRows']),
      hasLoginForm: json['hasLoginForm'] == true,
      hasEvaluationForm: json['hasEvaluationForm'] == true,
      error: json['error'] as String?,
    );
  }

  static List<Map<String, dynamic>> _listOfMaps(dynamic src) {
    if (src is! List) return [];
    return src.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Build radio groups from collected options.
  List<RadioGroup> get radioGroups => RadioGroup.fromOptionsList(radioOptions);

  /// Sanitized debug summary — no PII, no full page content.
  String get debugSummary => 'EvaluationProbeResult('
      'url=$url, title=$title, radioCount=$radioCount, '
      'textareaCount=$textareaCount, groups=${radioGroups.length}, '
      'hasLogin=$hasLoginForm, hasEval=$hasEvaluationForm, '
      'forms=${forms.length}, buttons=${buttons.length}, '
      'courseRows=${possibleCourseRows.length}'
      '${error != null ? ", error=$error" : ""})';
}

/// Result from the fill script execution.
class EvaluationFillResult {
  final int totalGroups;
  final int completedGroups;
  final List<String> unresolvedGroups;
  final int alreadyCompletedGroups;
  final int textareaCount;
  final List<String> requiredTextareas;
  final List<String> warnings;
  final String? error;

  const EvaluationFillResult({
    required this.totalGroups,
    required this.completedGroups,
    required this.unresolvedGroups,
    required this.alreadyCompletedGroups,
    required this.textareaCount,
    required this.requiredTextareas,
    required this.warnings,
    this.error,
  });

  factory EvaluationFillResult.fromJson(Map<String, dynamic> json) {
    return EvaluationFillResult(
      totalGroups: (json['totalGroups'] as int?) ?? 0,
      completedGroups: (json['completedGroups'] as int?) ?? 0,
      unresolvedGroups: _stringList(json['unresolvedGroups']),
      alreadyCompletedGroups: (json['alreadyCompletedGroups'] as int?) ?? 0,
      textareaCount: (json['textareaCount'] as int?) ?? 0,
      requiredTextareas: _stringList(json['requiredTextareas']),
      warnings: _stringList(json['warnings']),
      error: json['error'] as String?,
    );
  }

  factory EvaluationFillResult.error(String message) {
    return EvaluationFillResult(
      totalGroups: 0,
      completedGroups: 0,
      unresolvedGroups: [],
      alreadyCompletedGroups: 0,
      textareaCount: 0,
      requiredTextareas: [],
      warnings: [],
      error: message,
    );
  }

  bool get hasUnresolved => unresolvedGroups.isNotEmpty;
  bool get hasRequiredTextareas => requiredTextareas.isNotEmpty;
  bool get hasWarnings => warnings.isNotEmpty;
  bool get allCompleted => totalGroups > 0 && completedGroups >= totalGroups;

  static List<String> _stringList(dynamic src) {
    if (src is! List) return [];
    return src.map((e) => e.toString()).toList();
  }
}
