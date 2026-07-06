import sys

with open('e:/AI/xynewui/client/lib/screens/competition/competition_admin_import_screen.dart', 'r', encoding='utf-8') as f:
    lines = f.readlines()

# delete line 1315
if len(lines) > 1314 and lines[1314].strip() == '}':
    lines.pop(1314)

content = ''.join(lines)

if "import '../../widgets/competition/competition_status_helper.dart';" not in content:
    content = content.replace("import 'package:flutter/material.dart';", "import 'package:flutter/material.dart';\nimport '../../widgets/competition/competition_status_helper.dart';")

with open('e:/AI/xynewui/client/lib/screens/competition/competition_admin_import_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)
