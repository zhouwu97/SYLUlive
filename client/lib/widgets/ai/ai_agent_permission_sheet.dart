import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../services/ai_personal_data_permission_service.dart';
import '../../theme/app_motion.dart';
import '../campus/campus_theme.dart';

const aiAgentPermissionManagedScopes = <AiPersonalDataPermissionScope>[
  AiPersonalDataPermissionScope.deviceCacheAccess,
  AiPersonalDataPermissionScope.remoteEduRefresh,
  AiPersonalDataPermissionScope.erkeSnapshotUpload,
  AiPersonalDataPermissionScope.academicCloudStorage,
  AiPersonalDataPermissionScope.externalModelAnalysis,
];

bool aiAgentPermissionIsTrusted(
  Iterable<AiPersonalDataPermission> permissions,
) {
  final values =
      <AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>{
    for (final permission in permissions) permission.scope: permission.policy,
  };
  final enabledScopes = aiAgentPermissionManagedScopes.where(
    (scope) => values[scope] != AiPersonalDataPermissionPolicy.never,
  );
  return values[AiPersonalDataPermissionScope.personalDataAccess] ==
          AiPersonalDataPermissionPolicy.always &&
      enabledScopes.isNotEmpty &&
      enabledScopes.every(
        (scope) => values[scope] == AiPersonalDataPermissionPolicy.always,
      );
}

/// 校园 Agent 的用户-facing 权限设置。
///
/// 普通用户只看到“每次询问 / 完全信任”两种执行方式；服务端仍保留
/// ask / always / never 三种策略，能力开关用于细化完全信任的白名单范围。
class AiAgentPermissionSheet extends StatefulWidget {
  const AiAgentPermissionSheet({super.key, required this.dio});

  final Dio dio;

  static Future<void> show(BuildContext context, Dio dio) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      builder: (_) => AiAgentPermissionSheet(dio: dio),
    );
  }

  @override
  State<AiAgentPermissionSheet> createState() => _AiAgentPermissionSheetState();
}

class _AiAgentPermissionSheetState extends State<AiAgentPermissionSheet> {
  late final AiPersonalDataPermissionService _service;
  late Future<
          Map<AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>>
      _future;
  Map<AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>? _values;
  AiPersonalDataPermissionScope? _saving;

  static const _scopes = aiAgentPermissionManagedScopes;

  @override
  void initState() {
    super.initState();
    _service = AiPersonalDataPermissionService(widget.dio);
    _future = _load();
  }

  Future<Map<AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>>
      _load() async {
    final loaded = await _service.list();
    final values =
        <AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>{
      for (final scope in AiPersonalDataPermissionScope.values)
        scope: AiPersonalDataPermissionPolicy.ask,
    };
    for (final item in loaded) {
      values[item.scope] = item.policy;
    }
    if (mounted) setState(() => _values = values);
    return values;
  }

  bool get _trusted {
    final values = _values;
    if (values == null) return false;
    return aiAgentPermissionIsTrusted(
      values.entries.map(
        (entry) => AiPersonalDataPermission(
          scope: entry.key,
          policy: entry.value,
        ),
      ),
    );
  }

  Future<void> _setScope(
    AiPersonalDataPermissionScope scope,
    AiPersonalDataPermissionPolicy policy,
  ) async {
    final values = _values;
    if (values == null || _saving != null || values[scope] == policy) return;
    setState(() => _saving = scope);
    try {
      final updated = await _service.update(scope: scope, policy: policy);
      if (mounted) setState(() => values[updated.scope] = updated.policy);
    } on AiPersonalDataPermissionException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  Future<void> _setMode(bool trusted) async {
    final values = _values;
    if (values == null || _saving != null) return;
    final policy = trusted
        ? AiPersonalDataPermissionPolicy.always
        : AiPersonalDataPermissionPolicy.ask;
    final scopes = <AiPersonalDataPermissionScope>[
      AiPersonalDataPermissionScope.personalDataAccess,
      ..._scopes,
    ];
    for (final scope in scopes) {
      if (!mounted) return;
      if (values[scope] == AiPersonalDataPermissionPolicy.never) continue;
      await _setScope(scope, policy);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(maxHeight: 760),
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkCard : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: FutureBuilder<
          Map<AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 280,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError || _values == null) {
            return _buildError(colors);
          }
          return _buildContent(colors, isDark);
        },
      ),
    );
  }

  Widget _buildContent(ColorScheme colors, bool isDark) {
    final trusted = _trusted;
    return Column(
      children: [
        Semantics(
          label: '拖动关闭校园 Agent 权限',
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            decoration: BoxDecoration(
              color: colors.outlineVariant,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 16, 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isDark
                      ? colors.primaryContainer
                      : CampusTheme.primaryLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.shield_outlined, color: colors.primary),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('校园 Agent 权限',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    SizedBox(height: 3),
                    Text('完全信任只作用于已开启的安全能力范围',
                        style: TextStyle(fontSize: 12, height: 1.4)),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭权限设置',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            children: [
              _ModeSegment(
                trusted: trusted,
                onChanged: _setMode,
              ),
              const SizedBox(height: 20),
              Text(
                '允许 Agent 使用的能力',
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              for (final scope in _scopes) _buildScopeRow(scope, colors),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark
                      ? colors.surfaceContainerHighest
                      : const Color(0xFFFFF5EE),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '“完全信任”不是整台手机的完全访问。发帖、发私信、修改资料、删除内容、改密码和付款等高风险写操作，即使未来加入，也必须单独确认。',
                  style: TextStyle(
                    color: isDark ? colors.onSurface : const Color(0xFF8C5638),
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScopeRow(
    AiPersonalDataPermissionScope scope,
    ColorScheme colors,
  ) {
    final values = _values!;
    final policy = values[scope] ?? AiPersonalDataPermissionPolicy.ask;
    final enabled = policy != AiPersonalDataPermissionPolicy.never;
    final saving = _saving == scope;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        minVerticalPadding: 8,
        leading: Icon(_icon(scope), color: colors.primary),
        title: Text(_title(scope),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        subtitle: Text(_description(scope),
            style: const TextStyle(fontSize: 11, height: 1.35)),
        trailing: saving
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Switch(
                value: enabled,
                onChanged: (next) => _setScope(
                  scope,
                  next
                      ? (_trusted
                          ? AiPersonalDataPermissionPolicy.always
                          : AiPersonalDataPermissionPolicy.ask)
                      : AiPersonalDataPermissionPolicy.never,
                ),
              ),
      ),
    );
  }

  Widget _buildError(ColorScheme colors) {
    return SizedBox(
      height: 300,
      child: Center(
        child: FilledButton.icon(
          onPressed: () => setState(() {
            _values = null;
            _future = _load();
          }),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重新加载权限'),
        ),
      ),
    );
  }

  static String _title(AiPersonalDataPermissionScope scope) => switch (scope) {
        AiPersonalDataPermissionScope.deviceCacheAccess => '读取本地加密缓存',
        AiPersonalDataPermissionScope.remoteEduRefresh => 'AI 主动刷新教务',
        AiPersonalDataPermissionScope.erkeSnapshotUpload => '上传二课结构化摘要',
        AiPersonalDataPermissionScope.academicCloudStorage => '使用服务端学业快照',
        AiPersonalDataPermissionScope.externalModelAnalysis => '外部模型辅助分析',
        AiPersonalDataPermissionScope.personalDataAccess => '个人数据总开关',
      };

  static String _description(AiPersonalDataPermissionScope scope) =>
      switch (scope) {
        AiPersonalDataPermissionScope.deviceCacheAccess =>
          '只返回当前问题所需的成绩、课表或二课摘要。',
        AiPersonalDataPermissionScope.remoteEduRefresh =>
          '数据过旧时使用已有教务会话刷新，凭据不离开设备。',
        AiPersonalDataPermissionScope.erkeSnapshotUpload =>
          '只上传分类、缺口和活动数量，不上传凭据。',
        AiPersonalDataPermissionScope.academicCloudStorage =>
          '使用仍在有效期内的服务端学业快照。',
        AiPersonalDataPermissionScope.externalModelAnalysis =>
          '只发送去身份化后的必要结构化数据。',
        AiPersonalDataPermissionScope.personalDataAccess =>
          '关闭后校园 Agent 不再使用任何个人数据。',
      };

  static IconData _icon(AiPersonalDataPermissionScope scope) => switch (scope) {
        AiPersonalDataPermissionScope.deviceCacheAccess =>
          Icons.lock_outline_rounded,
        AiPersonalDataPermissionScope.remoteEduRefresh => Icons.sync_rounded,
        AiPersonalDataPermissionScope.erkeSnapshotUpload =>
          Icons.cloud_upload_outlined,
        AiPersonalDataPermissionScope.academicCloudStorage =>
          Icons.cloud_done_outlined,
        AiPersonalDataPermissionScope.externalModelAnalysis =>
          Icons.hub_outlined,
        AiPersonalDataPermissionScope.personalDataAccess =>
          Icons.shield_outlined,
      };
}

class _ModeSegment extends StatelessWidget {
  const _ModeSegment({required this.trusted, required this.onChanged});

  final bool trusted;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Agent 执行方式',
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.56),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(child: _item(context, '每次询问', !trusted, false)),
            Expanded(child: _item(context, '完全信任', trusted, true)),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, String label, bool selected, bool value) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppMotion.fast),
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? colors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.primary : colors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
