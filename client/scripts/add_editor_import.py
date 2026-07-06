import sys

with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

if "import 'competition_official_event_editor_screen.dart';" not in content:
    content = content.replace("import 'competition_admin_import_screen.dart';", "import 'competition_admin_import_screen.dart';\nimport 'competition_official_event_editor_screen.dart';")

with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)
