import re

# Fix edu.go
edu_go_path = 'server/internal/handlers/edu.go'
with open(edu_go_path, 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace('"当前学期课表暂未开放"', '"当前学期课表暂未排课"')

with open(edu_go_path, 'w', encoding='utf-8') as f:
    f.write(content)

# Fix SnackBars in edu_screen.dart
edu_screen_path = 'client/lib/screens/edu_screen.dart'
with open(edu_screen_path, 'r', encoding='utf-8') as f:
    dart_content = f.read()

# We will just replace `SnackBar(` with `SnackBar(behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), `
dart_content = dart_content.replace(
    'SnackBar(',
    'SnackBar(behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), '
)
# Wait, some are `const SnackBar(`. If we add `borderRadius: BorderRadius.circular(12)`, it might not be constant!
dart_content = dart_content.replace('const SnackBar(behavior: SnackBarBehavior.floating', 'SnackBar(behavior: SnackBarBehavior.floating')
dart_content = dart_content.replace('const SnackBar(', 'SnackBar(')

with open(edu_screen_path, 'w', encoding='utf-8') as f:
    f.write(dart_content)

print("Fixed")
