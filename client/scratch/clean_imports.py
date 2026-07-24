import os

def process_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original_content = content

    # If SharedPreferences is not used anymore (except in the import itself), remove the import
    if 'SharedPreferences' not in content.replace('import \'package:shared_preferences/shared_preferences.dart\';', ''):
        content = content.replace("import 'package:shared_preferences/shared_preferences.dart';\n", "")

    if content != original_content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"Cleaned {filepath}")

def main():
    test_dir = os.path.join('e:\\', 'AI', 'xynewui', 'client', 'test')
    lib_dir = os.path.join('e:\\', 'AI', 'xynewui', 'client', 'lib')
    
    for d in [lib_dir, test_dir]:
        for root, dirs, files in os.walk(d):
            for file in files:
                if file.endswith('.dart') and file != 'preferences_store.dart':
                    filepath = os.path.join(root, file)
                    process_file(filepath)

if __name__ == '__main__':
    main()
