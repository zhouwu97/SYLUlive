import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_ui_tokens.dart';

class CompetitionLegacyResolutionScreen extends StatefulWidget {
  const CompetitionLegacyResolutionScreen({super.key, required this.dio});

  final Dio dio;

  @override
  State<CompetitionLegacyResolutionScreen> createState() =>
      _CompetitionLegacyResolutionScreenState();
}

class _CompetitionLegacyResolutionScreenState
    extends State<CompetitionLegacyResolutionScreen> {
  bool _loading = true;
  int _total = 0;
  int _identityGroups = 0;
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
        '/admin/competition-catalog/legacy-resolutions',
        queryParameters: {'page_size': 100},
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      if (!mounted) return;
      setState(() {
        _total = (data['total'] as num?)?.toInt() ?? 0;
        _identityGroups = (data['identity_groups'] as num?)?.toInt() ?? 0;
        _items = ((data['items'] as List?) ?? const [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        _loading = false;
      });
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(error, fallback: '加载历史归并失败'),
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
        title: const Text('历史归并'),
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
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
                        '$_total 条旧记录归并审计 · $_identityGroups 个身份组',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    );
                  }
                  final item = _items[index - 1];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history_rounded),
                    title:
                        Text('${item['canonical_title'] ?? 'canonical 记录不存在'}'),
                    subtitle: Text(
                      'canonical ${item['canonical_event_id'] ?? '-'} · '
                      '旧记录 ${item['duplicate_event_id'] ?? '-'}\n'
                      '${item['reason'] ?? '历史重复归并'}',
                    ),
                  );
                },
              ),
            ),
    );
  }
}
