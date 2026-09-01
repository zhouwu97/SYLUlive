/// 周次解析结果。除了规范化后的集合，始终保留服务器原始表达式。
final class ParsedWeeks {
  ParsedWeeks({required Set<int> weeks, required this.raw})
      : weeks = Set.unmodifiable(weeks);

  final Set<int> weeks;
  final String raw;
}

/// 将教务系统的中文周次表达式解析为离散周集合。
abstract final class WeekParser {
  static ParsedWeeks parse(String raw) {
    final weeks = <int>{};
    if (raw.trim().isEmpty) {
      return ParsedWeeks(weeks: weeks, raw: raw);
    }

    final normalized = raw
        .replaceAll('，', ',')
        .replaceAll('－', '-')
        .replaceAll('—', '-')
        .replaceAll('～', '-')
        .replaceAll('至', '-')
        .replaceAll('到', '-');
    final rangePattern = RegExp(r'(\d+)\s*-\s*(\d+)|(\d+)');
    final onlyOddWeeks = raw.contains('单');
    final onlyEvenWeeks = raw.contains('双');

    for (final match in rangePattern.allMatches(normalized)) {
      final rangeStart = int.tryParse(match.group(1) ?? match.group(3) ?? '');
      final rangeEnd = int.tryParse(match.group(2) ?? '') ?? rangeStart;
      if (rangeStart == null || rangeEnd == null) continue;

      final lower = rangeStart <= rangeEnd ? rangeStart : rangeEnd;
      final upper = rangeStart <= rangeEnd ? rangeEnd : rangeStart;
      for (var week = lower; week <= upper; week++) {
        if (week < 1) continue;
        if (onlyOddWeeks && week.isEven) continue;
        if (onlyEvenWeeks && week.isOdd) continue;
        weeks.add(week);
      }
    }
    return ParsedWeeks(weeks: weeks, raw: raw);
  }
}
