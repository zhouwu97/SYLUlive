import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void>? _fontLoadFuture;

/// 在 widget/golden 测试中加载项目自带 CJK 字体。
///
/// 只加载 pubspec 实际声明的 `NotoSansCJKsc-Regular.otf`（w400）；
/// 不加载容器外字体、不复制字体文件、不为 w600/w700 伪造 font mapping。
/// 幂等：同一个测试进程只加载一次。
Future<void> loadTestFonts() {
  return _fontLoadFuture ??= _loadFonts();
}

Future<void> _loadFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final loader = FontLoader('NotoSansCJKsc')
    ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
  await loader.load();
}