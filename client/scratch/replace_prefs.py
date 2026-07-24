import os
import re

def process_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original_content = content

    # Add import if SharedPreferences is used and it's not the store itself
    if 'SharedPreferences' in content and not filepath.endswith('preferences_store.dart'):
        # Check if import already exists
        if 'platform/contracts/preferences_store.dart' not in content:
            # Add import after flutter or shared_preferences imports
            import_statement = "import 'package:shenliyuan/platform/contracts/preferences_store.dart';\n"
            
            # Simple heuristic to insert import
            lines = content.split('\n')
            last_import_idx = -1
            for i, line in enumerate(lines):
                if line.startswith('import '):
                    last_import_idx = i
            
            if last_import_idx != -1:
                lines.insert(last_import_idx + 1, import_statement)
                content = '\n'.join(lines)

        # Replace SharedPreferences.getInstance() with AppPreferencesStore.getInstance()
        content = content.replace('SharedPreferences.getInstance()', 'AppPreferencesStore.getInstance()')
        
        # Replace Type annotations: SharedPreferences -> AppPreferencesStore
        # Be careful not to replace it in imports like 'package:shared_preferences/shared_preferences.dart'
        content = re.sub(r'\bSharedPreferences\b(?!\.dart|\/)', 'AppPreferencesStore', content)

    if content != original_content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"Updated {filepath}")

def main():
    lib_dir = os.path.join('e:\\', 'AI', 'xynewui', 'client', 'lib')
    test_dir = os.path.join('e:\\', 'AI', 'xynewui', 'client', 'test')
    
    for root, dirs, files in os.walk(lib_dir):
        for file in files:
            if file.endswith('.dart'):
                filepath = os.path.join(root, file)
                process_file(filepath)
                
    for root, dirs, files in os.walk(test_dir):
        for file in files:
            if file.endswith('.dart'):
                filepath = os.path.join(root, file)
                process_file(filepath)

if __name__ == '__main__':
    main()
