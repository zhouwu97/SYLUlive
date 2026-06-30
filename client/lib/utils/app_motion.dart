import 'package:flutter/material.dart';

/// App 内部统一动效参数，避免页面之间的切换节奏各自发散。
class AppMotion {
  static const fast = Duration(milliseconds: 160);
  static const normal = Duration(milliseconds: 240);
  static const nav = Duration(milliseconds: 220);
  static const reveal = Duration(milliseconds: 360);
  static const page = Duration(milliseconds: 320);
  static const detail = Duration(milliseconds: 360);

  static const standard = Curves.easeOutCubic;
  static const incoming = Curves.easeOutCubic;
  static const outgoing = Curves.easeInCubic;
}
