import sys

def modify_center():
    with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    new_lines = []
    
    for i, line in enumerate(lines):
        if i == 20:
            new_lines.append("import 'competition_admin_import_screen.dart';\n")
            
        if 31 <= i < 144:
            continue
        if 1979 <= i < 3137:
            continue
        
        new_lines.append(line)
        
    with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'w', encoding='utf-8') as f:
        f.writelines(new_lines)

modify_center()
