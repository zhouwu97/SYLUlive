import re

with open('e:/AI/xynewui/client/lib/screens/competition/competition_admin_import_screen.dart', 'r', encoding='utf-8') as f:
    lines = f.readlines()

for i in [530, 598, 607, 617, 627, 695, 1095]:
    # line numbers are 1-indexed, so we subtract 1
    if i-1 < len(lines):
        lines[i-1] = lines[i-1].replace('const ', '')

content = ''.join(lines)

source_label = '''
String _sourceLabel(String value) {
  switch (value) {
    case 'school_catalog': return '学校目录';
    case 'college_notice': return '学院通知';
    case 'enterprise': return '企业赛';
    case 'industry_association': return '行业协会';
    case 'platform': return '竞赛平台';
    case 'admin_manual': return '管理员录入';
    case 'ai_import': return 'AI 导入';
    default: return value.isEmpty ? '未知来源' : value;
  }
}
'''

slug_hint = "const _competitionCategorySlugHint = 'innovation_startup、computer_ai、electronic_info、smart_manufacturing_vehicle、art_design、business_economics、math_science、materials_chem_env、language_humanities、defense_security_other';\n"

prompt_idx = content.find('const _competitionAiPrompt')
content = content[:prompt_idx] + slug_hint + content[prompt_idx:]

content += '\n' + source_label

with open('e:/AI/xynewui/client/lib/screens/competition/competition_admin_import_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)
