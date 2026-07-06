import re

with open('e:/AI/xynewui/client/lib/screens/competition/competition_admin_import_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

getters = '''
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _competitionBg => CompetitionUiTokens.pageBg(_isDark);
  Color get _competitionPrimary => CompetitionUiTokens.accent(_isDark);
  Color get _competitionPrimaryDark => CompetitionUiTokens.accent(_isDark);
  Color get _competitionLight => CompetitionUiTokens.accentSoft(_isDark);
  Color get _competitionBorder => CompetitionUiTokens.borderColor(_isDark);
  Color get _competitionMuted => CompetitionUiTokens.subColor(_isDark);
  Color get _competitionOrange => CompetitionUiTokens.warningColor(_isDark);
  Color get _competitionDanger => CompetitionUiTokens.dangerColor(_isDark);
  Color get _titleColor => CompetitionUiTokens.titleColor(_isDark);
  Color get _cardBg => CompetitionUiTokens.cardBg(_isDark);
'''

class_start = content.find('class _CompetitionAdminImportScreenState\n    extends State<CompetitionAdminImportScreen> {')
if class_start != -1:
    class_start = content.find('{', class_start) + 1
    content = content[:class_start] + getters + content[class_start:]
else:
    class_start = content.find('class _CompetitionAdminImportScreenState extends State<CompetitionAdminImportScreen> {')
    class_start = content.find('{', class_start) + 1
    content = content[:class_start] + getters + content[class_start:]

content = content.replace('Color(0xFF242330)', '_titleColor')
content = content.replace('Color(0xFF444150)', '_titleColor')
content = content.replace('Colors.white', '_cardBg')

content = content.replace('发布到官方比赛库', '导入到官方比赛库草稿')
content = content.replace('确认入库草稿', '导入为官方草稿')
content = content.replace("AppFeedback.showSnackBar(context, 'AI 导入已提交，默认进入草稿');", "AppFeedback.showSnackBar(context, '已导入到官方比赛库草稿，确认无误后可发布给所有用户');")
content = content.replace('Navigator.pop(context);', 'Navigator.pop(context, true);')

content = content.replace('先复制提示词给 AI', '第 1 步 让 AI 帮你整理比赛')
content = content.replace('把比赛通知、官网链接或公告原文一起发给 AI，让它只输出固定 JSON。然后把 JSON 粘贴到下面检查预览。', '把比赛通知发送给 AI，获取对应的 JSON。')
content = content.replace('维护建议：先维护长期稳定比赛和待更新条目，学校集中通知时再补充今年的链接和截止日期。', '')
content = content.replace('AI 不需要猜具体日期。不确定时间请标记为预计 / 往年参考 / 待通知，管理员确认后才会进入官方库。', '')
content = content.replace('分类 slug 必须使用系统已有分类；当前可用：$_competitionCategorySlugHint。', '')
content = content.replace('也可以直接导入 JSON 文件', '或者从文件导入')
content = content.replace('AI 生成的 JSON', '第 2 步 粘贴 AI 结果')

content = content.replace('const TextStyle', 'TextStyle')
content = content.replace('const BorderSide', 'BorderSide')
content = content.replace('const Icon', 'Icon')
content = content.replace('const Color', 'Color')
content = content.replace('const BoxDecoration', 'BoxDecoration')
content = content.replace('const Expanded', 'Expanded')
content = content.replace('const Row', 'Row')
content = content.replace('const Column', 'Column')
content = content.replace('const Padding', 'Padding')

helper_methods = '''
String _timeStatusLabel(String value) {
  switch (value) {
    case 'confirmed':
      return '已确认';
    case 'estimated':
      return '预计时间';
    case 'historical':
      return '往年参考';
    case 'pending':
      return '待通知';
    default:
      return value.isEmpty ? '待通知' : value;
  }
}

String competitionRecognitionLabel(String value) {
  switch (value) {
    case 'recognized':
      return '学校认定';
    case 'not_recognized':
      return '学校不认定';
    case 'unknown':
      return '认定未知';
    default:
      return '待认定';
  }
}

bool _draftHasExactDate(Map<String, dynamic> event) {
  final d1 = event['registration_start']?.toString() ?? '';
  final d2 = event['registration_end']?.toString() ?? '';
  final d3 = event['event_start']?.toString() ?? '';
  final d4 = event['event_end']?.toString() ?? '';
  return d1.isNotEmpty || d2.isNotEmpty || d3.isNotEmpty || d4.isNotEmpty;
}

String _draftValue(Map<String, dynamic> event, String key) {
  return event[key]?.toString() ?? '';
}

bool _draftEventHasWarning(Map<String, dynamic> event) {
  final level = _draftValue(event, 'recommendation_level');
  if (level.isEmpty) return true;
  return false;
}

DateTime? _draftSortDate(Map<String, dynamic> event) {
  final starts = [
    event['registration_start'],
    event['event_start'],
  ];
  for (var s in starts) {
    if (s != null && s.toString().isNotEmpty) {
      try {
        return DateTime.parse(s.toString());
      } catch (_) {}
    }
  }
  return null;
}
'''
content = content + '\n' + helper_methods

with open('e:/AI/xynewui/client/lib/screens/competition/competition_admin_import_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)
