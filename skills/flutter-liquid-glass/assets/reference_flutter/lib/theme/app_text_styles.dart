import 'package:flutter/material.dart';

/// 仅提供稳定的文本角色；页面仍应优先从 Theme.textTheme 取值。
abstract final class AppTextStyles {
  static const titleLarge = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.25,
  );
  static const titleMedium = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  static const bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );
  static const labelMedium = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );

  // 首页信息流角色：只供 PostCard(homeFeed) 使用，避免在卡片内散落排版魔法值。
  static const feedTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  static const feedBody = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );
  static const feedAuthor = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w700,
    height: 1.2,
  );
  static const feedMeta = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.25,
  );
  static const feedTime = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.2,
  );
  static const feedTag = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );
  static const feedBadge = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );
}
