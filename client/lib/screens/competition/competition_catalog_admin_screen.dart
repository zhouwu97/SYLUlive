import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/competition.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import 'competition_catalog_package_detail_screen.dart';

class CompetitionCatalogAdminScreen extends StatefulWidget {
  const CompetitionCatalogAdminScreen({super.key, required this.dio});

  final Dio dio;

  @override
  State<CompetitionCatalogAdminScreen> createState() =>
      _CompetitionCatalogAdminScreenState();
}

class _CompetitionCatalogAdminScreenState
    extends State<CompetitionCatalogAdminScreen> {
  bool _loading = true;
  List<CompetitionCatalogPackage> _packages = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final response = await widget.dio.get(
        '/admin/competition-catalog/packages',
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      final packages = ((data['items'] as List?) ?? const [])
          .map(
            (item) => CompetitionCatalogPackage.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _packages = packages;
        _loading = false;
      });
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(error, fallback: '加载目录包失败'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);
    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        title: const Text('目录包'),
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: _packages.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, index) => _packageTile(
                  context,
                  _packages[index],
                  isDark,
                ),
              ),
      ),
    );
  }

  Widget _packageTile(
    BuildContext context,
    CompetitionCatalogPackage package,
    bool isDark,
  ) {
    return Material(
      color: CompetitionUiTokens.cardBg(isDark),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CompetitionCatalogPackageDetailScreen(
              dio: widget.dio,
              package: package,
              activePackageId: _packages
                  .where((item) => item.isActive)
                  .map((item) => item.id)
                  .firstOrNull,
            ),
          ),
        ),
        leading: Icon(
          package.isActive
              ? Icons.check_circle_rounded
              : Icons.inventory_2_outlined,
          color: package.isActive
              ? Colors.green.shade600
              : CompetitionUiTokens.subColor(isDark),
        ),
        title: Text(
          package.datasetVersion,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            '包 ${package.id} · revision ${package.revision} · ${package.itemCount} 条\n'
            '${_statusLabel(package)} · ${_shortHash(package.packageHash)}',
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

String _statusLabel(CompetitionCatalogPackage package) {
  if (package.isActive) return '活动目录';
  if (package.lifecycleStatus == 'retired') return '已退役';
  if (package.publishStatus == 'draft') return '草稿暂存';
  return '待发布修订';
}

String _shortHash(String value) {
  if (value.length <= 16) return value;
  return '${value.substring(0, 8)}...${value.substring(value.length - 8)}';
}
