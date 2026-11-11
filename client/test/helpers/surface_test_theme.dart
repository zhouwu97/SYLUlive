import 'package:shenliyuan/providers/theme_provider.dart';

/// 像素测试采样同一位置的底图时临时隐藏共享底色，正常帧使用生产映射。
class SurfaceTestTheme extends ThemeProvider {
  SurfaceTestTheme() : super(loadOnStart: false);

  bool _surfacesHidden = false;

  void setSurfacesHidden(bool value) {
    _surfacesHidden = value;
    notifyListeners();
  }

  @override
  double get effectiveComponentOpacity =>
      _surfacesHidden ? 0 : super.effectiveComponentOpacity;
}
