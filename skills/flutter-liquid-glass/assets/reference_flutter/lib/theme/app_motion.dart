import 'package:flutter/material.dart';

/// App 内部统一动效参数，避免页面之间的切换节奏各自发散。
///
/// 这里的值是语义档位，不是页面可以随意复制的魔法数字。高频路径
/// 默认不做内容动画；确有反馈需求时，才使用 micro/tab 这两个短档位。
abstract final class AppMotion {
  // 高频即时反馈。
  static const micro = Duration(milliseconds: 100);
  static const tab = Duration(milliseconds: 120);

  // 普通组件变化。
  static const fast = Duration(milliseconds: 160);
  static const normal = Duration(milliseconds: 220);

  // Overlay / Sheet / Dialog。
  static const overlay = Duration(milliseconds: 240);

  // 页面空间关系与首次内容建立。
  static const page = Duration(milliseconds: 280);
  static const reveal = Duration(milliseconds: 320);

  static const standard = Curves.easeOutCubic;
  static const incoming = Curves.easeOutCubic;
  static const outgoing = Curves.easeOutCubic;

  // 已经存在于屏幕上的元素从 A 移动到 B；最终曲线待真机 A/B 冻结。
  static const movement = Curves.easeInOutCubic;

  /// 根据系统的 reduced-motion 设置收窄动效时长。
  ///
  /// reduced motion 不等于完全没有反馈：保留极短的 opacity/color 变化，
  /// 但避免大距离位移、scale 和装饰性 stagger 阻碍操作确认。
  static Duration duration(
    BuildContext context,
    Duration value, {
    Duration reduced = const Duration(milliseconds: 40),
  }) {
    return MediaQuery.disableAnimationsOf(context) ? reduced : value;
  }

  static bool reducedMotion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  // 临时兼容别名：迁移完成后删除，禁止新代码使用。
  @Deprecated('Use AppMotion.tab instead.')
  static const nav = Duration(milliseconds: 220);

  @Deprecated('Use AppMotion.page instead.')
  static const detail = Duration(milliseconds: 360);
}
