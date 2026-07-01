import 'dart:convert';

import 'package:flutter/material.dart';

/// 校园资讯允许的官方域名白名单。
/// 精确枚举，不使用 endsWith 避免伪造子域名。
const Set<String> allowedCampusArticleHosts = {
  'jwc.sylu.edu.cn',
  'cxcyxy.sylu.edu.cn',
};

/// 校园资讯 URL 是否安全（HTTPS + 白名单域名）。
bool isSafeCampusUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  return uri != null &&
      uri.scheme == 'https' &&
      allowedCampusArticleHosts.contains(uri.host);
}

/// 校园资讯文章数据模型。
///
/// 后端接口：
/// - GET /api/campus/articles/latest  → {item: DetailItem | null}
/// - GET /api/campus/articles         → {items, page, page_size, has_more, last_sync_at}
/// - GET /api/campus/articles/:id     → {item: DetailItem}
///
/// 列表接口只返回摘要字段，详情接口才包含正文和附件。

/// 文章附件。
class CampusAttachment {
  final String name;
  final String url;
  final String extension;

  const CampusAttachment({
    required this.name,
    required this.url,
    this.extension = '',
  });

  factory CampusAttachment.fromJson(Map<String, dynamic> json) {
    return CampusAttachment(
      name: json['name']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      extension: json['extension']?.toString() ?? '',
    );
  }

  /// 根据扩展名返回对应的图标。
  IconData get icon {
    final ext = extension.toLowerCase();
    if (ext == 'xls' || ext == 'xlsx') return Icons.table_chart_rounded;
    if (ext == 'doc' || ext == 'docx') return Icons.description_rounded;
    if (ext == 'pdf') return Icons.picture_as_pdf_rounded;
    if (ext == 'zip' || ext == 'rar' || ext == '7z') {
      return Icons.folder_zip_rounded;
    }
    return Icons.attach_file_rounded;
  }

  /// 附件地址是否安全（仅允许白名单域名的 HTTPS 链接）。
  bool get isUrlSafe => isSafeCampusUrl(url);

  /// 用于显示的扩展名标签（大写）。
  String get extensionLabel {
    final ext = extension.toUpperCase();
    if (ext.isEmpty) return '附件';
    return ext;
  }
}

/// 文章摘要，用于首页和列表页。
class CampusArticleSummary {
  final int id;
  final String source;
  final String category;
  final String categorySlug;
  final String title;
  final String publishDate;
  final String authorDepartment;
  final String sourceUrl;
  final bool hasAttachment;

  const CampusArticleSummary({
    required this.id,
    this.source = '',
    this.category = '',
    this.categorySlug = '',
    this.title = '',
    this.publishDate = '',
    this.authorDepartment = '',
    this.sourceUrl = '',
    this.hasAttachment = false,
  });

  factory CampusArticleSummary.fromJson(Map<String, dynamic> json) {
    return CampusArticleSummary(
      id: _parseInt(json['id']),
      source: json['source']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      categorySlug: json['category_slug']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      publishDate: json['publish_date']?.toString() ?? '',
      authorDepartment: json['author_department']?.toString() ?? '',
      sourceUrl: json['source_url']?.toString() ?? '',
      hasAttachment: json['has_attachment'] == true,
    );
  }

  /// 短日期格式（MM-DD），用于列表和卡片显示。
  String get shortDate {
    if (publishDate.length >= 10) {
      final parts = publishDate.substring(5, 10).split('-');
      if (parts.length == 2) {
        return '${parts[0]}-${parts[1]}';
      }
    }
    return publishDate;
  }
}

/// 文章详情，在摘要基础上增加正文和附件。
class CampusArticleDetail extends CampusArticleSummary {
  final String contentText;
  final String contentHtml;
  final List<CampusAttachment> attachments;

  const CampusArticleDetail({
    required super.id,
    super.source,
    super.category,
    super.categorySlug,
    super.title,
    super.publishDate,
    super.authorDepartment,
    super.sourceUrl,
    super.hasAttachment,
    this.contentText = '',
    this.contentHtml = '',
    this.attachments = const [],
  });

  factory CampusArticleDetail.fromJson(Map<String, dynamic> json) {
    return CampusArticleDetail(
      id: _parseInt(json['id']),
      source: json['source']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      categorySlug: json['category_slug']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      publishDate: json['publish_date']?.toString() ?? '',
      authorDepartment: json['author_department']?.toString() ?? '',
      sourceUrl: json['source_url']?.toString() ?? '',
      hasAttachment: json['has_attachment'] == true,
      contentText: json['content_text']?.toString() ?? '',
      contentHtml: json['content_html']?.toString() ?? '',
      attachments: _parseAttachments(json['attachments']),
    );
  }

  /// 从摘要构造详情（用于详情页加载时先显示已有信息）。
  factory CampusArticleDetail.fromSummary(CampusArticleSummary summary) {
    return CampusArticleDetail(
      id: summary.id,
      source: summary.source,
      category: summary.category,
      categorySlug: summary.categorySlug,
      title: summary.title,
      publishDate: summary.publishDate,
      authorDepartment: summary.authorDepartment,
      sourceUrl: summary.sourceUrl,
      hasAttachment: summary.hasAttachment,
    );
  }

  /// 是否为弱正文（正文为空或仅"详见附件"等提示语）。
  bool get isWeakContent {
    final trimmed = contentText.trim();
    if (trimmed.isEmpty) return true;
    // 去除末尾标点后判断
    final normalized = trimmed.replaceAll(RegExp(r'[:：。.\s]+$'), '');
    return ['详见附件', '见附件'].contains(normalized);
  }

  /// 正文是否包含复杂 HTML（表格、图片等），用于引导用户查看原文。
  bool get hasComplexHtml {
    return contentHtml.contains('<table') ||
        contentHtml.contains('<img') ||
        contentHtml.contains('<iframe');
  }
}

/// 分页响应。
class CampusArticlePage {
  final List<CampusArticleSummary> items;
  final int page;
  final int pageSize;
  final bool hasMore;
  final DateTime? lastSyncAt;

  const CampusArticlePage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.hasMore,
    this.lastSyncAt,
  });

  factory CampusArticlePage.fromJson(Map<String, dynamic> json) {
    final itemsRaw = json['items'];
    final items = <CampusArticleSummary>[];
    if (itemsRaw is List) {
      for (final e in itemsRaw) {
        if (e is Map<String, dynamic>) {
          items.add(CampusArticleSummary.fromJson(e));
        }
      }
    }

    final lastSyncStr = json['last_sync_at']?.toString();
    DateTime? lastSync;
    if (lastSyncStr != null && lastSyncStr.isNotEmpty) {
      lastSync = DateTime.tryParse(lastSyncStr);
    }

    return CampusArticlePage(
      items: items,
      page: _parseInt(json['page'], fallback: 1),
      pageSize: _parseInt(json['page_size'], fallback: 20),
      hasMore: json['has_more'] == true,
      lastSyncAt: lastSync,
    );
  }
}

// ── 内部辅助函数 ─────────────────────────────────────────────────

int _parseInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

List<CampusAttachment> _parseAttachments(dynamic raw) {
  if (raw == null) return [];
  if (raw is List) {
    return raw
        .whereType<Map<String, dynamic>>()
        .map((e) => CampusAttachment.fromJson(e))
        .toList();
  }
  // attachments 有可能是 JSON 字符串
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'null') return [];
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map((e) => CampusAttachment.fromJson(e))
            .toList();
      }
    } catch (_) {
      return [];
    }
  }
  return [];
}
