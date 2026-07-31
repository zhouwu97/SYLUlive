import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/competition.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import 'competition_catalog_mapping_screen.dart';

class CompetitionCatalogPackageDetailScreen extends StatelessWidget {
  const CompetitionCatalogPackageDetailScreen({
    super.key,
    required this.dio,
    required this.package,
    this.activePackageId,
  });

  final Dio dio;
  final CompetitionCatalogPackage package;
  final int? activePackageId;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);
    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        title: Text('目录包 ${package.id}'),
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _section(
              '版本',
              [
                _row('数据集', package.datasetVersion),
                _row('修订', '${package.revision}'),
                _row('状态', package.isActive ? '活动目录' : package.lifecycleStatus),
                _row('发布声明', package.publishStatus),
                _row('生产加载', package.productionLoadAllowed ? '允许' : '禁止'),
              ],
              isDark),
          _section(
              '内容',
              [
                _row('赛事数量', '${package.itemCount}'),
                _row('校验', package.validationStatus),
                _row(
                    '来源文件',
                    package.sourceFilename.isEmpty
                        ? '未记录'
                        : package.sourceFilename),
                _row('Package hash', package.packageHash),
              ],
              isDark),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: () => _showDiff(context),
                icon: const Icon(Icons.difference_outlined),
                label: const Text('查看 Diff'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CompetitionCatalogMappingScreen(
                      dio: dio,
                      package: package,
                      activePackageId: activePackageId,
                    ),
                  ),
                ),
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('查看映射'),
              ),
              if (!package.isActive &&
                  package.publishStatus == 'published' &&
                  package.productionLoadAllowed)
                FilledButton.icon(
                  onPressed: () => _runPreflight(context),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('预检'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: CompetitionUiTokens.cardBg(isDark),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: CompetitionUiTokens.borderColor(isDark)),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text(value, maxLines: 3, overflow: TextOverflow.ellipsis),
    );
  }

  Future<void> _showDiff(BuildContext context) async {
    try {
      final response = await dio.get(
        '/admin/competition-catalog/packages/${package.id}/diff',
      );
      if (!context.mounted) return;
      final data = Map<String, dynamic>.from(response.data as Map);
      int count(String key) => ((data[key] as List?) ?? const []).length;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('目录差异'),
          content: Text(
            '新增 ${count('added')} 条\n移除 ${count('removed')} 条\n变更 ${count('changed')} 条',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } on DioException catch (error) {
      if (!context.mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(error, fallback: '获取 Diff 失败'),
        isError: true,
      );
    }
  }

  Future<void> _runPreflight(BuildContext context) async {
    try {
      final response = await dio.post(
        '/admin/competition-catalog/packages/${package.id}/preflight',
      );
      if (!context.mounted) return;
      final data = Map<String, dynamic>.from(response.data as Map);
      final report = data['report'] is Map
          ? Map<String, dynamic>.from(data['report'] as Map)
          : const <String, dynamic>{};
      final blockers =
          ((report['blocking_issues'] as List?) ?? const []).length;
      AppFeedback.showSnackBar(
          context, blockers == 0 ? '预检通过' : '预检发现 $blockers 项阻断');
    } on DioException catch (error) {
      if (!context.mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(error, fallback: '预检失败'),
        isError: true,
      );
    }
  }
}
