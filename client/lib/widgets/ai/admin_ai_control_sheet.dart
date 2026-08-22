import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/ai_runtime/ai_provider_storage.dart';
import '../../features/ai_runtime/ai_model_provider.dart';
import '../../providers/auth_provider.dart';
import '../../screens/ai/ai_model_settings_screen.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';

/// 管理员专属 AI 控制面板。官方运行数据只显示服务端返回值，不填充演示数字。
class AdminAiControlSheet extends StatefulWidget {
  const AdminAiControlSheet({super.key, required this.dio});

  final Dio dio;

  static Future<void> show(BuildContext context, Dio dio) {
    if (context.read<AuthProvider>().user?.isAdmin != true) {
      return Future<void>.value();
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      builder: (_) => AdminAiControlSheet(dio: dio),
    );
  }

  @override
  State<AdminAiControlSheet> createState() => _AdminAiControlSheetState();
}

class _AdminAiControlSheetState extends State<AdminAiControlSheet> {
  int _tab = 0;
  Map<String, dynamic>? _metrics;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMetrics();
  }

  Future<void> _loadMetrics() async {
    try {
      final response = await widget.dio.get(
        '/admin/ai/metrics',
        queryParameters: const <String, dynamic>{'days': 1},
      );
      if (response.data is! Map) {
        throw const FormatException('指标响应格式错误');
      }
      if (mounted) {
        setState(
            () => _metrics = Map<String, dynamic>.from(response.data as Map));
      }
    } on DioException catch (error) {
      if (mounted) {
        setState(
            () => _error = '生产指标暂不可用（${error.response?.statusCode ?? '网络'}）');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '生产指标暂不可用');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(maxHeight: 760),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.borderNormalLight,
                  borderRadius: BorderRadius.circular(AppRadius.pill))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
            child: Row(
              children: [
                const Icon(Icons.tune_rounded, color: AppColors.brandPrimary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('AI 调用管理',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      SizedBox(height: 3),
                      Text('仅管理员可见 · 生产与个人调试隔离',
                          style: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.textSecondaryLight)),
                    ],
                  ),
                ),
                IconButton(
                    tooltip: '关闭 AI 调用管理',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded)),
              ],
            ),
          ),
          _Tabs(
              index: _tab, onChanged: (value) => setState(() => _tab = value)),
          Expanded(child: _tab == 0 ? _officialPanel() : _minePanel()),
        ],
      ),
    );
  }

  Widget _officialPanel() {
    final metrics = _metrics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: AppColors.brandSurfaceLight,
              borderRadius: BorderRadius.circular(AppRadius.md)),
          child: Row(
            children: [
              const Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('AI Runtime 状态',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    SizedBox(height: 3),
                    Text('校园 Agent、MCP、设备桥接状态来自当前服务',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textSecondaryLight))
                  ])),
              Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.pill)),
                  child: Text(
                      _loading
                          ? '检查中'
                          : _error == null
                              ? '生产在线'
                              : '状态未知',
                      style: const TextStyle(
                          fontSize: 10.5,
                          color: AppColors.brandPrimary,
                          fontWeight: FontWeight.w700))),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_error != null)
          _InlineNotice(message: _error!, onRetry: _loadMetrics),
        _MetricGrid(metrics: metrics),
        const SizedBox(height: 14),
        _Section(title: '生产模型', child: _modelSummary(metrics)),
        const SizedBox(height: 12),
        _Section(title: '最近调用', child: _recentCalls(metrics)),
        const SizedBox(height: 12),
        const Text('费用、Token、错误码与延迟均由服务端 usage ledger 聚合；客户端不自行计算，也不展示密钥。',
            style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: AppColors.textSecondaryLight)),
      ],
    );
  }

  Widget _minePanel() {
    final user = context.read<AuthProvider>().user;
    final appUserId = user?.id.toString() ?? '';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      children: [
        const Text('我的 AI',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        const Text('复用个人助手的本机 Provider 配置。只影响当前管理员自己的测试，不改变官方 AI 或普通用户路由。',
            style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: AppColors.textSecondaryLight)),
        const SizedBox(height: 14),
        _Section(
          title: 'Provider',
          child: FutureBuilder<AIModelProviderConfig?>(
            future: appUserId.isEmpty
                ? Future.value(null)
                : AIProviderSettingsStore(appUserId: appUserId).readConfig(),
            builder: (context, snapshot) {
              final config = snapshot.data;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ConfigRow(
                      label: 'Provider',
                      value: config == null ? '暂不可用' : 'OpenAI Compatible'),
                  _ConfigRow(
                      label: 'Base URL', value: config?.endpoint ?? '暂不可用'),
                  _ConfigRow(label: 'Model', value: config?.model ?? '暂不可用'),
                  const _ConfigRow(label: 'API Key', value: '仅保存在本机安全存储'),
                  const SizedBox(height: 10),
                  SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                          onPressed: appUserId.isEmpty
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                      builder: (_) => AIModelSettingsScreen(
                                          appUserId: appUserId))),
                          child: const Text('打开我的 AI 设置'))),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        const _Section(
            title: '测试边界',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('✓ 普通对话', style: TextStyle(fontSize: 12.5)),
              SizedBox(height: 6),
              Text('✓ Tool Calling（只读/模拟工具）', style: TextStyle(fontSize: 12.5)),
              SizedBox(height: 6),
              Text('○ 真实 MCP 数据（需要单独授权）', style: TextStyle(fontSize: 12.5)),
              SizedBox(height: 10),
              Text('测试请求不会写入生产数据。',
                  style: TextStyle(
                      fontSize: 11.5, color: AppColors.textSecondaryLight))
            ])),
      ],
    );
  }

  Widget _modelSummary(Map<String, dynamic>? metrics) {
    final models = metrics?['models'];
    if (models is! List || models.isEmpty) {
      return const Text('暂不可用',
          style:
              TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight));
    }
    return Column(children: [
      for (final item in models.whereType<Map>())
        _ConfigRow(
            label: '${item['name'] ?? '模型'}',
            value: '${item['role'] ?? '状态未知'}')
    ]);
  }

  Widget _recentCalls(Map<String, dynamic>? metrics) {
    final calls = metrics?['recent_calls'];
    if (calls is! List || calls.isEmpty) {
      return const Text('暂不可用',
          style:
              TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight));
    }
    return Column(children: [
      for (final item in calls.whereType<Map>())
        _ConfigRow(
            label: '${item['purpose'] ?? '调用'}',
            value: '${item['status'] ?? '状态未知'}')
    ]);
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(children: [
          Expanded(
              child: _Tab(
                  label: '官方 AI',
                  selected: index == 0,
                  onTap: () => onChanged(0))),
          Expanded(
              child: _Tab(
                  label: '我的 AI',
                  selected: index == 1,
                  onTap: () => onChanged(1)))
        ]),
      );
}

class _Tab extends StatelessWidget {
  const _Tab(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
          onTap: onTap,
          child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          color: selected
                              ? AppColors.brandPrimary
                              : Colors.transparent,
                          width: 2))),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      color: selected
                          ? AppColors.brandPrimary
                          : AppColors.textSecondaryLight,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500)))));
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});
  final Map<String, dynamic>? metrics;

  @override
  Widget build(BuildContext context) {
    String value(String key) {
      final raw = metrics?[key];
      if (raw == null) {
        return '暂不可用';
      }
      if (key == 'success_rate' && raw is num) {
        return '${(raw * 100).toStringAsFixed(1)}%';
      }
      return raw.toString();
    }

    return GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.9,
        children: [
          _Metric(label: '今日调用', value: value('requests')),
          _Metric(label: '成功率', value: value('success_rate')),
          _Metric(label: 'Token', value: value('input_output_tokens')),
          _Metric(
              label: '今日费用', value: metrics?['cost_yuan']?.toString() ?? '暂不可用')
        ]);
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.surfaceMutedDark
              : const Color(0xFFF8FBF8),
          borderRadius: BorderRadius.circular(AppRadius.sm)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 10.5, color: AppColors.textSecondaryLight)),
            const SizedBox(height: 4),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))
          ]));
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.surfaceMutedDark
              : Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppColors.borderNormalDark
                  : AppColors.borderNormalLight)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        child
      ]));
}

class _ConfigRow extends StatelessWidget {
  const _ConfigRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondaryLight))),
        Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)))
      ]));
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        const Icon(Icons.info_outline_rounded,
            size: 16, color: AppColors.warning),
        const SizedBox(width: 6),
        Expanded(
            child: Text(message,
                style:
                    const TextStyle(fontSize: 11.5, color: AppColors.warning))),
        TextButton(onPressed: onRetry, child: const Text('重试'))
      ]));
}
