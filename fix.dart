import 'dart:io';

void main() {
  final dir = Directory('e:/AI/xynewui/client/lib/screens/');
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.dart'));
  for (final file in files) {
    if (file.path.contains('settings_screen.dart') || 
        file.path.contains('shuitie_screen.dart') || 
        file.path.contains('post_detail_screen.dart')) {
      continue;
    }
    String content = file.readAsStringSync();
    bool changed = false;
    if (content.contains('themeProvider.backgroundImage')) {
      content = content.replaceAll('themeProvider.backgroundImage', 'themeProvider.getBackgroundImageFor(context)');
      changed = true;
    }
    if (content.contains('themeProvider.hasBackground')) {
      content = content.replaceAll('themeProvider.hasBackground', 'themeProvider.isBackgroundVisible');
      changed = true;
    }
    if (content.contains('p.backgroundImage')) {
      content = content.replaceAll('p.backgroundImage', 'p.getBackgroundImageFor(context)');
      changed = true;
    }
    if (content.contains('p.hasBackground')) {
      content = content.replaceAll('p.hasBackground', 'p.isBackgroundVisible');
      changed = true;
    }
    if (changed) {
      file.writeAsStringSync(content);
      print('Updated \${file.path}');
    }
  }
}
