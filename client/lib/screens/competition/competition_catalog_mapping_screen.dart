import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/competition.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_ui_tokens.dart';

class CompetitionCatalogMappingScreen extends StatefulWidget {
  const CompetitionCatalogMappingScreen({
    super.key,
    required this.dio,
    required this.package,
    this.activePackageId,
  });

  final Dio dio;
  final CompetitionCatalogPackage package;
  final int? activePackageId;

  @override
  State<CompetitionCatalogMappingScreen> createState() =>
      _CompetitionCatalogMappingScreenState();
}

class _CompetitionCatalogMappingScreenState
    extends State<CompetitionCatalogMappingScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final response = await widget.dio.get(
        '/admin/competition-catalog/packages/${widget.package.id}/mappings',
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      final items = ((data['items'] as List?) ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(error, fallback: '加载映射失败'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed =
        _items.where((item) => item['review_status'] == 'confirmed').length;
    final conflicts =
        _items.where((item) => item['review_status'] == 'conflict').length;
    return Scaffold(
      backgroundColor: CompetitionUiTokens.pageBg(isDark),
      appBar: AppBar(
        title: const Text('映射审核'),
        backgroundColor: CompetitionUiTokens.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
        actions: [
          if (!widget.package.isActive && widget.activePackageId != null)
            IconButton(
              tooltip: '继承活动包映射',
              onPressed: _inherit,
              icon: const Icon(Icons.move_down_rounded),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                itemCount: _items.length + 1,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(
                        '${_items.length} 条映射 · $confirmed 已确认 · $conflicts 冲突',
                        style: TextStyle(
                          color: CompetitionUiTokens.subColor(isDark),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  final item = _items[index - 1];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${item['competition_title'] ?? ''}'),
                    subtitle: Text(
                      '${item['competition_id'] ?? ''}\n'
                      '旧事件 ${item['legacy_event_id'] ?? '-'} · ${item['match_type'] ?? '未映射'}',
                    ),
                    trailing: _statusIcon('${item['review_status'] ?? ''}'),
                  );
                },
              ),
            ),
    );
  }

  Widget _statusIcon(String status) {
    if (status == 'confirmed') {
      return const Icon(Icons.check_circle_rounded, color: Colors.green);
    }
    if (status == 'conflict') {
      return const Icon(Icons.error_outline_rounded, color: Colors.red);
    }
    return const Icon(Icons.help_outline_rounded);
  }

  Future<void> _inherit() async {
    try {
      final response = await widget.dio.post(
        '/admin/competition-catalog/packages/${widget.package.id}/mappings/inherit',
        data: {'from_package_id': widget.activePackageId},
      );
      if (!mounted) return;
      final data = Map<String, dynamic>.from(response.data as Map);
      AppFeedback.showSnackBar(
        context,
        '继承 ${data['inherited'] ?? 0} 条，跳过 ${data['skipped'] ?? 0} 条，冲突 ${data['conflicts'] ?? 0} 条',
      );
      await _load();
    } on DioException catch (error) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(error, fallback: '继承映射失败'),
        isError: true,
      );
    }
  }
}
