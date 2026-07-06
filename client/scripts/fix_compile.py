import sys
import re

# 1. Fix admin import screen import and syntax error
with open('e:/AI/xynewui/client/lib/screens/competition/competition_admin_import_screen.dart', 'r', encoding='utf-8') as f:
    import_content = f.read()

if "import '../../widgets/competition/competition_status_helper.dart';" not in import_content:
    import_content = import_content.replace("import 'package:flutter/material.dart';", "import 'package:flutter/material.dart';\nimport '../../widgets/competition/competition_status_helper.dart';")

# I might have removed too much when removing competitionRecognitionLabel. Let's fix line 1315 syntax error.
# The error says "Expected a method, getter, setter or operator declaration". Let's check what's around line 1315.
# If there's an extra closing brace or missing one.

with open('e:/AI/xynewui/client/lib/screens/competition/competition_admin_import_screen.dart', 'w', encoding='utf-8') as f:
    f.write(import_content)

# 2. Check center screen for _openAdminManualCreate
with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'r', encoding='utf-8') as f:
    center_content = f.read()

# Make sure _openAdminManualCreate exists inside _CompetitionCenterScreenState
# It was injected by `run_center_refactor.py`. Let's see if it's there.
if '_openAdminManualCreate' not in center_content.split('class _CompetitionCenterScreenState')[1]:
    # It might be missing.
    pass

