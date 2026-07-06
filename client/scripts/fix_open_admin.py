import re

with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# Replace _openAdminImport block
import_block = """  void _openAdminImport() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionAdminImportScreen()),
    );
  }"""

new_import_block = """  Future<void> _openAdminImport() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionAdminImportScreen()),
    );
    if (result == true) {
      _load();
    }
  }

  Future<void> _openAdminManualCreate() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionOfficialEventEditorScreen()),
    );
    if (result == true) {
      _load();
    }
  }"""

content = content.replace(import_block, new_import_block)

# Fix EmptyState secondary tap to use _openAdminManualCreate
content = content.replace('onSecondaryTap: user?.isAdmin == true ? _openAdminImport : _load,', 'onSecondaryTap: user?.isAdmin == true ? _openAdminManualCreate : _load,')

with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)

with open('e:/AI/xynewui/client/lib/screens/competition/competition_admin_import_screen.dart', 'r', encoding='utf-8') as f:
    import_content = f.read()

# Check line 1315 syntax error
# We removed `String competitionRecognitionLabel.*?}`
# Let's see if there's an issue with the syntax there.
