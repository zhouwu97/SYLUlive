import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app_bootstrap.dart';
import '../widgets/app_page_app_bar.dart';
import 'court_screen.dart';

/// 管理员处理陪审人数不足、平票等 review_required 案件。
class AdminAppealReviewScreen extends StatefulWidget {
  const AdminAppealReviewScreen({super.key});

  @override
  State<AdminAppealReviewScreen> createState() =>
      _AdminAppealReviewScreenState();
}

enum _ReviewLoadError {
  /// 403 – 当前管理员无法访问该接口。
  forbidden,

  /// 网络不可达 / 超时 / 无 response。
  network,

  /// 服务端返回 5xx 或其他非 2xx。
  server,

  /// 未知异常。
  unknown,
}

class _AdminAppealReviewScreenState extends State<AdminAppealReviewScreen> {
  bool _loading = true;
  _ReviewLoadError? _errorKind;
  String? _errorDetail;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorKind = null;
      _errorDetail = null;
    });
    try {
      final response = await getSharedDio().get('/admin/appeals/review');
      final data = response.data;
      final raw = data is List
          ? data
          : data is Map && data['appeals'] is List
              ? data['appeals'] as List
              : const <dynamic>[];
      if (mounted) {
        setState(() => _items = raw
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList());
      }
    } on DioException catch (error) {
      debugPrint(
          '[AdminAppealReview] 请求失败: '
          'status=${error.response?.statusCode}, '
          'type=${error.type}, '
          'body=${error.response?.data}');
      if (mounted) {
        final status = error.response?.statusCode;
        if (status == 403 || status == 401) {
          _errorKind = _ReviewLoadError.forbidden;
          _errorDetail = error.response?.data is Map
              ? error.response?.data['error']?.toString()
              : null;
        } else if (error.response == null) {
          // 无 response — 网络不可达 / 连接超时 / DNS 失败
          _errorKind = _ReviewLoadError.network;
        } else {
          _errorKind = _ReviewLoadError.server;
          _errorDetail = error.response?.data is Map
              ? error.response?.data['error']?.toString()
              : null;
        }
        setState(() {});
      }
    } catch (error) {
      debugPrint('[AdminAppealReview] 未知异常: $error');
      if (mounted) setState(() => _errorKind = _ReviewLoadError.unknown);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openDetail(Map<String, dynamic> appeal) async {
    final id = (appeal['id'] as num?)?.toInt();
    if (id == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => CourtScreen(appealId: id, adminReviewMode: true)),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const AppPageAppBar(title: Text('公众法庭复核')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _errorKind != null
                ? _buildErrorState()
                : _items.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 180),
                        Center(child: Text('暂无待人工复核案件'))
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (_, index) => _buildCard(_items[index]),
                      ),
      ),
    );
  }

  Widget _buildErrorState() {
    final IconData icon;
    final String title;
    final String subtitle;

    switch (_errorKind!) {
      case _ReviewLoadError.forbidden:
        icon = Icons.lock_outline;
        title = '你暂无公众法庭复核权限';
        subtitle = _errorDetail ?? '请确认你的管理员身份是否拥有复核权限';
      case _ReviewLoadError.network:
        icon = Icons.wifi_off;
        title = '网络连接异常';
        subtitle = '请检查网络后重试';
      case _ReviewLoadError.server:
        icon = Icons.cloud_off;
        title = '待复核案件暂时无法加载';
        subtitle = _errorDetail ?? '请稍后重试；若持续出现，请联系超级管理员';
      case _ReviewLoadError.unknown:
        icon = Icons.error_outline;
        title = '待复核案件加载失败';
        subtitle = '发生未知错误，请稍后重试';
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 使用 ListView 使 RefreshIndicator 仍可下拉刷新。
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.22),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 48,
                    color: isDark ? Colors.white38 : Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isDark ? Colors.white54 : Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重新加载'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCard(Map<String, dynamic> appeal) {
    return Card(
      child: InkWell(
        onTap: () => _openDetail(appeal),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('案件 #${appeal['id'] ?? '-'}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('社区内容治理复核'),
            const SizedBox(height: 8),
            Text((appeal['result'] ?? '案件需要人工复核').toString(),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.visibility_outlined,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text('查看匿名证据并进行人工裁决',
                  style: Theme.of(context).textTheme.labelLarge),
            ]),
          ]),
        ),
      ),
    );
  }
}
