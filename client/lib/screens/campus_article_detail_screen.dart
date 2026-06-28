import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../models/campus_article.dart';
import '../services/campus_article_service.dart';
import '../utils/app_feedback.dart';

/// 文章详情页。
///
/// 接收摘要信息（标题、分类、日期等）用于即时显示页面框架，
/// 然后异步拉取完整详情（正文、附件）。
class CampusArticleDetailScreen extends StatefulWidget {
  final CampusArticleSummary summary;

  const CampusArticleDetailScreen({super.key, required this.summary});

  @override
  State<CampusArticleDetailScreen> createState() =>
      _CampusArticleDetailScreenState();
}

class _CampusArticleDetailScreenState extends State<CampusArticleDetailScreen> {
  late CampusArticleService _service;
  CampusArticleDetail? _detail;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _service = CampusArticleService(getSharedDio());
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final detail = await _service.getArticleDetail(widget.summary.id);
      if (mounted) {
        setState(() {
          _detail = detail;
          _isLoading = false;
        });
      }
    } on CampusArticleServiceException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message;
          _isLoading = false;
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = AppFeedback.dioErrorMessage(
            e,
            serviceName: '校园资讯',
            fallback: '加载文章详情失败',
          );
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '加载文章详情失败';
          _isLoading = false;
        });
      }
    }
  }

  /// 打开外部浏览器访问指定 URL。
  ///
  /// 仅允许白名单域名的 HTTPS 链接。
  Future<void> _openExternalUrl(String url, {String? errorText}) async {
    if (!isSafeCampusUrl(url)) {
      AppFeedback.showSnackBar(
        context,
        errorText ?? '附件地址无效',
        isError: true,
      );
      return;
    }
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        AppFeedback.showSnackBar(context, '无法打开浏览器', isError: true);
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '无法打开浏览器', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final summary = widget.summary;
    final detail = _detail;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF101219) : const Color(0xFFF8F7FC),
      appBar: AppBar(
        title: const Text('文章详情'),
        backgroundColor: isDark ? const Color(0xFF1B1E28) : Colors.white,
        foregroundColor: isDark ? Colors.white : const Color(0xFF20212B),
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadDetail,
          child: _buildBody(context, isDark, summary, detail),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    bool isDark,
    CampusArticleSummary summary,
    CampusArticleDetail? detail,
  ) {
    if (_isLoading && detail == null) {
      return _buildLoadingState(isDark);
    }

    if (detail == null && _errorMessage != null) {
      return _buildErrorState(isDark, _errorMessage!);
    }

    if (detail == null) {
      // 理论上不会走到这里，但防御性处理
      return _buildLoadingState(isDark);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        _buildHeader(isDark, detail),
        const SizedBox(height: 20),
        _buildContentSection(isDark, detail),
        if (detail.attachments.isNotEmpty) ...[
          const SizedBox(height: 20),
          _buildAttachmentSection(isDark, detail.attachments),
        ],
        const SizedBox(height: 24),
        _buildSourceLink(isDark, detail.sourceUrl),
        if (_errorMessage != null && detail != null) ...[
          const SizedBox(height: 16),
          _buildInlineRetry(isDark),
        ],
      ],
    );
  }

  // ── 加载状态 ───────────────────────────────────────────────────

  Widget _buildLoadingState(bool isDark) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        _buildHeaderSkeleton(isDark),
        const SizedBox(height: 20),
        _buildContentSkeleton(isDark),
      ],
    );
  }

  Widget _buildHeaderSkeleton(bool isDark) {
    final baseColor = isDark ? const Color(0xFF1B1E28) : Colors.white;
    final shimmerColor = isDark ? Colors.white12 : const Color(0xFFEDEBF3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 80,
          height: 24,
          decoration: BoxDecoration(
            color: shimmerColor,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 24,
          decoration: BoxDecoration(
            color: shimmerColor,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: 200,
          height: 14,
          decoration: BoxDecoration(
            color: shimmerColor,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ],
    );
  }

  Widget _buildContentSkeleton(bool isDark) {
    final shimmerColor = isDark ? Colors.white12 : const Color(0xFFEDEBF3);
    return Container(
      height: 120,
      decoration: BoxDecoration(
        color: shimmerColor,
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }

  // ── 错误状态 ───────────────────────────────────────────────────

  Widget _buildErrorState(bool isDark, String message) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        _buildHeaderSkeleton(isDark),
        const SizedBox(height: 20),
        _buildRetryCard(isDark, message),
      ],
    );
  }

  Widget _buildRetryCard(bool isDark, String message) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 40,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: _loadDetail,
            child: const Text('点击重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineRetry(bool isDark) {
    return Center(
      child: TextButton.icon(
        onPressed: _loadDetail,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('重新加载'),
      ),
    );
  }

  // ── 文章头部 ───────────────────────────────────────────────────

  Widget _buildHeader(bool isDark, CampusArticleDetail detail) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分类标签
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            detail.category.isNotEmpty ? detail.category : '校园资讯',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: primary,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 标题
        Text(
          detail.title,
          style: TextStyle(
            fontSize: 20,
            height: 1.4,
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : const Color(0xFF20212B),
          ),
        ),
        const SizedBox(height: 10),
        // 日期 · 部门
        Text(
          [
            if (detail.publishDate.isNotEmpty) detail.publishDate,
            if (detail.authorDepartment.isNotEmpty) detail.authorDepartment,
          ].join(' · '),
          style: TextStyle(
            fontSize: 12.5,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
        ),
      ],
    );
  }

  // ── 正文区域 ───────────────────────────────────────────────────

  Widget _buildContentSection(bool isDark, CampusArticleDetail detail) {
    final hasAttachments = detail.attachments.isNotEmpty;

    // 弱正文且有附件 → 显示附件提示
    if (detail.isWeakContent && hasAttachments) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1B1E28) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 20,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '该通知的主要内容位于附件中，请前往学校网站验证后下载。',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 有正文 → 显示正文
    if (detail.contentText.trim().isNotEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1B1E28) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
          ),
        ),
        child: SelectableText(
          detail.contentText,
          style: TextStyle(
            fontSize: 15,
            height: 1.75,
            color: isDark
                ? Colors.white.withValues(alpha: 0.87)
                : const Color(0xFF2C2D38),
          ),
        ),
      );
    }

    // 正文为空且无附件 → 引导查看原文
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 20,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '该通知未提取到正文内容，请查看学校原文获取完整信息。',
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 附件区域 ───────────────────────────────────────────────────

  Widget _buildAttachmentSection(
    bool isDark,
    List<CampusAttachment> attachments,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '附件（${attachments.length}）',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : const Color(0xFF292A35),
          ),
        ),
        const SizedBox(height: 8),
        // 验证码提示
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: (isDark ? Colors.amber : Colors.orange).withValues(
              alpha: 0.1,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 16,
                color: isDark ? Colors.amber.shade300 : Colors.orange.shade700,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '学校附件需要输入验证码，请在浏览器中完成验证。',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        isDark ? Colors.amber.shade300 : Colors.orange.shade700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final attachment in attachments) ...[
          _buildAttachmentCard(isDark, attachment),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildAttachmentCard(bool isDark, CampusAttachment attachment) {
    final primary = Theme.of(context).colorScheme.primary;
    final isUrlSafe = attachment.isUrlSafe;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
        ),
      ),
      child: Row(
        children: [
          // 扩展名图标
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(attachment.icon, color: primary, size: 22),
          ),
          const SizedBox(width: 12),
          // 文件名 + 提示
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      attachment.extensionLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        attachment.name.isNotEmpty ? attachment.name : '未知文件',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color:
                              isDark ? Colors.white : const Color(0xFF292A35),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isUrlSafe ? '需前往学校网站验证后下载' : '附件地址无效',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: isDark ? Colors.white38 : Colors.black45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 下载按钮
          TextButton(
            onPressed: isUrlSafe
                ? () => _openExternalUrl(attachment.url)
                : () => AppFeedback.showSnackBar(
                      context,
                      '附件地址无效',
                      isError: true,
                    ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 36),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.open_in_new_rounded,
                  size: 16,
                  color: isUrlSafe
                      ? primary
                      : (isDark ? Colors.white24 : Colors.black26),
                ),
                const SizedBox(width: 4),
                Text(
                  '前往浏览器下载',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: isUrlSafe
                        ? primary
                        : (isDark ? Colors.white24 : Colors.black26),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 查看学校原文 ───────────────────────────────────────────────

  Widget _buildSourceLink(bool isDark, String sourceUrl) {
    final primary = Theme.of(context).colorScheme.primary;
    final isUrlSafe = isSafeCampusUrl(sourceUrl);

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: isUrlSafe
            ? () => _openExternalUrl(sourceUrl, errorText: '原文地址无效')
            : () => AppFeedback.showSnackBar(
                  context,
                  '原文地址无效',
                  isError: true,
                ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          side: BorderSide(
            color: isUrlSafe
                ? primary.withValues(alpha: 0.4)
                : (isDark ? Colors.white10 : const Color(0xFFEDEBF3)),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: Icon(
          Icons.link_rounded,
          size: 18,
          color:
              isUrlSafe ? primary : (isDark ? Colors.white24 : Colors.black26),
        ),
        label: Text(
          '查看学校原文',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isUrlSafe
                ? primary
                : (isDark ? Colors.white24 : Colors.black26),
          ),
        ),
      ),
    );
  }
}
