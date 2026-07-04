import 'package:flutter/material.dart';

import '../config/water_post_taxonomy.dart';

/// 水帖版块内标签
class WaterSectionTag {
  final int id;
  final int sectionId;
  final String slug;
  final String name;
  final String description;
  final int sortOrder;
  final bool isDefault;
  final bool isEnabled;

  const WaterSectionTag({
    required this.id,
    required this.sectionId,
    required this.slug,
    required this.name,
    this.description = '',
    this.sortOrder = 0,
    this.isDefault = false,
    this.isEnabled = true,
  });

  factory WaterSectionTag.fromJson(Map<String, dynamic> json) {
    return WaterSectionTag(
      id: json['id'] ?? 0,
      sectionId: json['section_id'] ?? 0,
      slug: json['slug'] ?? '',
      name: json['name'] ?? '',
      description: json['description'] ?? '',
      sortOrder: json['sort_order'] ?? 0,
      isDefault: json['is_default'] == true,
      isEnabled: json['is_enabled'] != false,
    );
  }

  Map<String, dynamic> toUpdateJson({
    String? reason,
    bool includeSlug = false,
  }) {
    return {
      if (includeSlug) 'slug': slug,
      'name': name,
      'description': description,
      'sort_order': sortOrder,
      'is_default': isDefault,
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    };
  }
}

/// 水帖版块（一级容器）
class WaterSection {
  final int id;
  final String slug;
  final String title;
  final String subtitle;
  final String description;
  final String iconKey;
  final String colorHex;
  final String publishActionText;
  final String emptyTitle;
  final String emptyDescription;
  final List<String> starterQuestions;
  final String noticeText;
  final String sensitiveLevel;
  final String defaultSort;
  final int sortOrder;
  final String status;
  final bool isFollowed;
  final List<WaterSectionTag> tags;

  const WaterSection({
    required this.id,
    required this.slug,
    required this.title,
    this.subtitle = '',
    this.description = '',
    this.iconKey = '',
    this.colorHex = '',
    this.publishActionText = '发布帖子',
    this.emptyTitle = '',
    this.emptyDescription = '',
    this.starterQuestions = const [],
    this.noticeText = '',
    this.sensitiveLevel = 'normal',
    this.defaultSort = 'recommend',
    this.sortOrder = 0,
    this.status = 'active',
    this.isFollowed = false,
    this.tags = const [],
  });

  factory WaterSection.fromJson(Map<String, dynamic> json) {
    final tagsRaw = json['tags'] as List<dynamic>? ?? const [];
    final tags = tagsRaw
        .map((e) => WaterSectionTag.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return WaterSection(
      id: json['id'] ?? 0,
      slug: json['slug'] ?? '',
      title: json['title'] ?? '',
      subtitle: json['subtitle'] ?? '',
      description: json['description'] ?? '',
      iconKey: json['icon_key'] ?? '',
      colorHex: json['color_hex'] ?? '',
      publishActionText: json['publish_action_text'] ?? '发布帖子',
      emptyTitle: json['empty_title'] ?? '',
      emptyDescription: json['empty_description'] ?? '',
      starterQuestions: (json['starter_questions'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      noticeText: json['notice_text'] ?? '',
      sensitiveLevel: json['sensitive_level'] ?? 'normal',
      defaultSort: json['default_sort'] ?? 'recommend',
      sortOrder: json['sort_order'] ?? 0,
      status: json['status'] ?? 'active',
      isFollowed: json['is_followed'] == true,
      tags: tags,
    );
  }

  Map<String, dynamic> toDisplayUpdateJson({String? reason}) {
    return {
      'title': title,
      'subtitle': subtitle,
      'description': description,
      'icon_key': iconKey,
      'color_hex': colorHex,
      'publish_action_text': publishActionText,
      'empty_title': emptyTitle,
      'empty_description': emptyDescription,
      'starter_questions': starterQuestions,
      'notice_text': noticeText,
      'default_sort': defaultSort,
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    };
  }

  /// 已启用标签（按 sort_order）
  List<WaterSectionTag> get enabledTags =>
      tags.where((t) => t.isEnabled).toList();

  bool get isSensitive =>
      sensitiveLevel == 'caution' || sensitiveLevel == 'strict';

  /// 将旧客户端硬编码分类转成 fallback WaterSection（接口失败时使用）
  factory WaterSection.fromLegacyCategory(WaterPostCategory category) {
    return WaterSection(
      id: 0,
      slug: category.value,
      title: category.label,
      subtitle: category.hint,
      description: category.hint,
      iconKey: '',
      colorHex:
          '#${category.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      publishActionText: category.publishActionText,
      emptyTitle: category.emptyTitle,
      emptyDescription: category.emptyDescription,
      starterQuestions: category.starterQuestions,
      noticeText: sensitiveLevelFor(category.value) ?? '',
      sensitiveLevel: sensitiveLevelForSlug(category.value),
      defaultSort: 'recommend',
      sortOrder: 0,
      status: 'active',
      tags: const [],
    );
  }

  static String sensitiveLevelForSlug(String slug) {
    switch (slug) {
      case 'complaint':
        return 'caution';
      case 'campus_news':
        return 'strict';
      default:
        return 'normal';
    }
  }

  static String? sensitiveLevelFor(String slug) {
    switch (slug) {
      case 'complaint':
        return '请理性表达，避免公开他人隐私、联系方式、学号、手机号或未经证实的指控。';
      case 'campus_news':
        return '请客观描述事实，避免挂人、泄露隐私、传播未经证实的信息。';
      default:
        return null;
    }
  }
}

/// iconKey -> IconData 映射；后端未配置时按 slug 兜底
IconData iconKeyToIconData(String iconKey, {String fallbackSlug = ''}) {
  switch (iconKey) {
    case 'school':
      return Icons.school_outlined;
    case 'menu_book':
      return Icons.menu_book_outlined;
    case 'emoji_events':
      return Icons.emoji_events_outlined;
    case 'local_florist':
      return Icons.local_florist_outlined;
    case 'mood':
      return Icons.chat_bubble_outline;
    case 'lightbulb':
      return Icons.lightbulb_outline;
    case 'warning':
      return Icons.report_problem_outlined;
    default:
      // 无 iconKey 时按 slug 兜底
      switch (fallbackSlug) {
        case 'freshman_help':
          return Icons.school_outlined;
        case 'course_study':
          return Icons.menu_book_outlined;
        case 'competition':
          return Icons.emoji_events_outlined;
        case 'campus_life':
          return Icons.local_florist_outlined;
        case 'complaint':
          return Icons.chat_bubble_outline;
        case 'experience':
          return Icons.lightbulb_outline;
        case 'campus_news':
          return Icons.report_problem_outlined;
        default:
          return Icons.forum_outlined;
      }
  }
}

/// colorHex -> Color；解析失败走 fallback
Color colorHexToColor(String colorHex,
    {Color fallback = const Color(0xFF6E7681)}) {
  if (colorHex.isEmpty) return fallback;
  var hex = colorHex;
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 6) hex = 'FF$hex';
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return fallback;
  return Color(value);
}

/// 由 section 推荐 sort 值，适配现有 posts 接口枚举（time/all/featured/following）
String defaultSortForSection(WaterSection section) {
  switch (section.defaultSort) {
    case 'recommend':
    case 'all':
      return 'all';
    case 'latest':
    case 'time':
      return 'time';
    case 'featured':
      return 'featured';
    case 'following':
      return 'following';
    default:
      return 'all';
  }
}
