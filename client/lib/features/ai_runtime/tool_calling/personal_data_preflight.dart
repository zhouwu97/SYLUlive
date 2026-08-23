import 'tool_call_models.dart';

/// 为明确的个人数据分析生成确定性的首个读取动作。
///
/// 读取动作由客户端根据用户问题选择，模型只能在拿到结果后继续分析；
/// 这里不读取完整账号数据，只读取与问题最相关的最小概览。
class PersonalDataPreflightPlanner {
  const PersonalDataPreflightPlanner._();

  static List<LocalToolCall> plan({
    required String message,
    required Set<String> allowedToolIds,
    DateTime? now,
  }) {
    final normalized = message.trim().toLowerCase();
    if (!_isAnalysisIntent(normalized)) return const <LocalToolCall>[];

    final calls = <LocalToolCall>[];
    void add(String tool, Map<String, dynamic> arguments) {
      if (allowedToolIds.contains(tool)) {
        calls.add(
          LocalToolCall(
            id: 'preflight-${calls.length + 1}',
            tool: tool,
            arguments: arguments,
          ),
        );
      }
    }

    final anchor = now ?? DateTime.now();
    final isSchedule = _containsAny(
      normalized,
      <String>['课表', '课程', '空闲', '有课', '安排', '时间', '周计划'],
    );
    final isAcademic = _containsAny(
      normalized,
      <String>['成绩', '学业', 'gpa', '绩点', '学分', '挂科', '风险'],
    );
    final isPhysical =
        _containsAny(normalized, <String>['体测', '身体', '体重', '身高']);
    final isErke = _containsAny(normalized, <String>['二课', '第二课堂']);
    final isCompetition = _containsAny(normalized, <String>['竞赛', '比赛', '参赛']);

    if (isSchedule) {
      final day = _dateOnly(
        normalized.contains('明天')
            ? anchor.add(const Duration(days: 1))
            : anchor,
      );
      if (_containsAny(normalized, <String>['今天', '明天'])) {
        add('personal.schedule.today', <String, dynamic>{
          'date': _dateText(day),
        });
      } else {
        final weekAnchor = normalized.contains('下周')
            ? anchor.add(const Duration(days: 7))
            : anchor;
        add('personal.schedule.week', <String, dynamic>{
          'week_containing': _dateText(_dateOnly(weekAnchor)),
        });
      }
    } else if (isAcademic) {
      add('personal.academic.overview', const <String, dynamic>{});
    } else if (isPhysical) {
      add('personal.physical.overview', const <String, dynamic>{});
    } else if (isErke) {
      add('personal.erke.overview', const <String, dynamic>{});
    } else if (isCompetition) {
      add('explain_competition_matches', const <String, dynamic>{});
      if (calls.isEmpty) {
        add('get_competition_capability_profile', const <String, dynamic>{});
      }
    } else if (_containsAny(normalized, <String>['我的', '个人', '根据我', '适合我'])) {
      // 无法判定领域时，优先读取当前周安排；这是低敏感、范围最小的个人事实。
      add('personal.schedule.week', <String, dynamic>{
        'week_containing': _dateText(_dateOnly(anchor)),
      });
    }
    return List<LocalToolCall>.unmodifiable(calls);
  }

  static bool _isAnalysisIntent(String message) => _containsAny(
        message,
        <String>['分析', '评估', '判断', '建议', '推荐', '规划', '风险', '适合'],
      );

  static bool _containsAny(String value, List<String> candidates) =>
      candidates.any(value.contains);

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static String _dateText(DateTime value) {
    String pad(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${pad(value.month)}-${pad(value.day)}';
  }
}
