import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/canteen.dart';
import '../models/canteen_ranking.dart' show SummaryTag;
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../services/publish_session_scope.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_card.dart';
import '../widgets/app_page_background.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_merchant_form.dart';
import '../widgets/canteen/canteen_status_image.dart';
import '../widgets/canteen/canteen_theme.dart';

/// 唯一的商家资料编辑页。资料与展示标签在服务端同一事务中保存。
class AdminCanteenEditorScreen extends StatefulWidget {
  const AdminCanteenEditorScreen({super.key, required this.canteen});
  final Canteen canteen;

  @override
  State<AdminCanteenEditorScreen> createState() =>
      _AdminCanteenEditorScreenState();
}

class _AdminCanteenEditorScreenState extends State<AdminCanteenEditorScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final AuthProvider _auth;
  late final PublishSessionScope _scope;
  bool _loading = true,
      _saving = false,
      _automatic = true,
      _leaving = false,
      _confirmingLeave = false;
  String? _loadError, _saveError;
  String _area = '', _floor = '', _initialArea = '', _initialFloor = '';
  bool _initialAutomatic = true;
  final _tags = <String>[];
  List<String> _initialTags = const [];
  List<SummaryTag>? _automaticTags;
  int _loadGeneration = 0;

  bool get _sessionValid =>
      _scope.owns(
          userId: _auth.user?.id, sessionEpoch: _auth.accountSessionEpoch) &&
      _auth.user?.isAdmin == true &&
      (!widget.canteen.isOffline || _auth.user?.role == 'super_admin');

  bool get _dirty =>
      _name.text.trim() != widget.canteen.name ||
      _area != _initialArea ||
      _floor != _initialFloor ||
      _automatic != _initialAutomatic ||
      (!_automatic && !listEquals(_tags, _initialTags));

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.canteen.name)
      ..addListener(_changed);
    _auth = context.read<AuthProvider>();
    _scope = PublishSessionScope(
      accountId: _auth.user?.id ?? 0,
      accountSessionEpoch: _auth.accountSessionEpoch,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _sessionValid) _load();
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_sessionValid) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final provider = context.read<CanteenProvider>();
    try {
      await provider.loadMeta(forceRefresh: true);
      if (!mounted || !_sessionValid || generation != _loadGeneration) return;
      if (!provider.supportsUnifiedManagement) {
        throw UnsupportedError('当前服务尚未支持统一编辑，请更新服务后重试');
      }
      final data = await provider.getDisplayTags(widget.canteen.id);
      if (!mounted || !_sessionValid || generation != _loadGeneration) return;
      _initialArea = _area = data['location_area'] as String? ?? '';
      _initialFloor = _floor = data['location_floor'] as String? ?? '';
      _initialAutomatic = _automatic = data['tags'] == null;
      _initialTags = (data['tags'] as List? ?? []).cast<String>().toList();
      _automaticTags = (data['automatic_tags'] as List?)
          ?.map((tag) =>
              SummaryTag.fromJson(Map<String, dynamic>.from(tag as Map)))
          .toList();
      _tags
        ..clear()
        ..addAll(_initialTags);
    } on DioException catch (e) {
      _loadError = switch (e.response?.statusCode) {
        401 => '登录已失效，请重新登录后再试',
        403 => '当前账号没有管理这家商家的权限',
        404 => '商家不存在或当前服务尚未支持统一编辑',
        _ => '加载商家设置失败，请重试',
      };
    } on UnsupportedError catch (e) {
      _loadError = e.message;
    } catch (_) {
      _loadError = '加载商家设置失败，请重试';
    } finally {
      if (mounted && _sessionValid && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _save() async {
    if (_saving ||
        _loading ||
        _loadError != null ||
        !_sessionValid ||
        !_form.currentState!.validate()) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final provider = context.read<CanteenProvider>();
    final ok = await provider.adminUpdateCanteen(
      widget.canteen.id,
      name: _name.text.trim(),
      locationArea: _area,
      locationFloor: _area == '其他' ? '' : _floor,
      updateTags: true,
      tags: _automatic ? null : List.of(_tags),
      sessionScope: _scope,
    );
    if (!mounted || !_sessionValid) return;
    if (ok) {
      setState(() {
        _leaving = true;
        _saving = false;
      });
      // 等 PopScope 的 canPop 更新后再退出。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sessionValid) Navigator.pop(context, true);
      });
    } else {
      setState(() {
        _saving = false;
        _saveError = provider.errorMessage ?? '保存失败，输入已保留，请重试';
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_saveError!)));
    }
  }

  Future<void> _confirmLeave() async {
    if (_saving || _confirmingLeave) return;
    _confirmingLeave = true;
    final leave = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
              title: const Text('放弃本次修改？'),
              content: const Text('尚未保存的修改会丢失。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('继续编辑')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('放弃修改')),
              ],
            ));
    _confirmingLeave = false;
    if (leave == true && mounted) {
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  List<({String key, String label})> get _previewTags {
    if (_automatic) {
      return (_automaticTags ?? [])
          .map((tag) => (key: tag.key, label: tag.name))
          .toList();
    }
    final labels = {
      for (final tag in context.read<CanteenProvider>().reviewTags)
        tag.key: tag.label
    };
    return _tags.map((key) => (key: key, label: labels[key]!)).toList();
  }

  Widget _merchantPreview() {
    final shop = widget.canteen;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final tags = _previewTags;
    final locationParts = [
      shop.isOffline ? '已下架' : '营业中',
      _area,
      if (_area != '其他') _floor
    ].where((part) => part.isNotEmpty).toList();
    Widget placeholder() => Tooltip(
        message: '暂无封面',
        child: ColoredBox(
          color: CanteenTheme.surfaceMutedBg(dark),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.storefront_outlined,
                size: 28, color: scheme.onSurfaceVariant),
            const SizedBox(height: 6),
            Text('无封面',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ));
    return AppCardSurface(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(dark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
              child: Text('展示预览',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w600))),
          Text('随编辑更新',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox.square(
                dimension: 80,
                child: CanteenStatusImage(
                    imageUrl: shop.image,
                    offline: shop.isOffline,
                    variant: 'thumb',
                    width: 80,
                    height: 80,
                    placeholder: (_, __) => placeholder(),
                    errorWidget: (_, __, ___) => placeholder()),
              )),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(_name.text.trim().isEmpty ? '商家名称' : _name.text.trim(),
                    key: const ValueKey('merchant-preview-name'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontSize: 19, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Semantics(
                  key: const ValueKey('merchant-preview-location'),
                  label: locationParts.join(' · '),
                  excludeSemantics: true,
                  child: Wrap(spacing: 6, runSpacing: 3, children: [
                    for (var index = 0; index < locationParts.length; index++)
                      Text(
                          index == 0
                              ? locationParts[index]
                              : '· ${locationParts[index]}',
                          softWrap: false,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                  ]),
                ),
                const SizedBox(height: 7),
                if (shop.ratingCount == 0)
                  Text('暂无评价',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant))
                else
                  Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.star_rounded,
                              size: 19,
                              color: CanteenTheme.accentStrongColor(dark)),
                          const SizedBox(width: 3),
                          Text(shop.averageStar.toStringAsFixed(1),
                              style: theme.textTheme.titleMedium?.copyWith(
                                  color: CanteenTheme.accentStrongColor(dark),
                                  fontWeight: FontWeight.w700)),
                        ]),
                        Text('${shop.ratingCount} 人评价',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
              ])),
        ]),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            key: const ValueKey('merchant-tag-preview'),
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var index = 0; index < tags.length; index++)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                      color: CanteenTheme.surfaceMutedBg(dark),
                      borderRadius: BorderRadius.circular(6)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(tags[index].label,
                        key: ValueKey('preview-tag-${tags[index].key}'),
                        style: theme.textTheme.bodySmall),
                    if (_automatic) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: '${_automaticTags![index].count} 次提及',
                        child: Text('${_automaticTags![index].count}',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      ),
                    ],
                  ]),
                ),
            ],
          ),
        ],
        const AppCardDivider(height: 24),
        Text('${shop.dishCount} 道菜 · ${shop.dishPhotoCount} 张实拍',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _editorContent(CanteenProvider provider) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sectionStyle =
        theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.canteen.isOffline)
        const CanteenFormNotice('已下架，仅修改资料，不会恢复营业。'),
      if (_saveError != null) CanteenFormNotice(_saveError!, error: true),
      CanteenMerchantNameField(controller: _name, enabled: !_saving),
      const SizedBox(height: 24),
      CanteenLocationFields(
        areas: provider.locationAreas,
        floors: provider.locationFloors,
        area: _area,
        floor: _floor,
        allowUnset: true,
        enabled: !_saving,
        onAreaChanged: (value) => setState(() {
          _area = value;
          if (value == '其他') _floor = '';
        }),
        onFloorChanged: (value) => setState(() => _floor = value),
      ),
      const AppCardDivider(height: 28),
      Row(children: [
        Expanded(child: Text('展示标签', style: sectionStyle)),
        if (!_automatic)
          Text('${_tags.length}/3',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: 12),
      Container(
        key: const ValueKey('merchant-tag-mode'),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
            color: CanteenTheme.surfaceMutedBg(
                theme.brightness == Brightness.dark),
            borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          for (final mode in [true, false])
            Expanded(
              child: Semantics(
                key: ValueKey('merchant-tag-mode-$mode'),
                selected: _automatic == mode,
                inMutuallyExclusiveGroup: true,
                child: TextButton(
                  onPressed: _saving
                      ? null
                      : () {
                          FocusScope.of(context).unfocus();
                          setState(() => _automatic = mode);
                        },
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 11),
                    foregroundColor: _automatic == mode
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                    backgroundColor: _automatic == mode
                        ? CanteenTheme.surfaceBg(
                            theme.brightness == Brightness.dark)
                        : Colors.transparent,
                    side: _automatic == mode
                        ? BorderSide(
                            color: scheme.outlineVariant.withValues(alpha: .7))
                        : BorderSide.none,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7)),
                    textStyle: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: _automatic == mode
                            ? FontWeight.w600
                            : FontWeight.w400),
                  ).copyWith(visualDensity: VisualDensity.standard),
                  child: Text(mode ? '自动汇总' : '手动选择'),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      Text(_automatic ? '近 30 天有效评价 · 最多展示 3 个' : '按选择顺序展示，最多 3 个',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant)),
      if (_automatic && _previewTags.isEmpty) ...[
        const SizedBox(height: 12),
        Text(_automaticTags == null ? '保存后根据近期评价自动更新' : '暂无可汇总的评价标签',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
      ],
      if (!_automatic) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final tag in provider.reviewTags)
            FilterChip(
              label: Text(tag.label),
              selected: _tags.contains(tag.key),
              showCheckmark: false,
              avatar: _tags.contains(tag.key)
                  ? CircleAvatar(
                      radius: 9,
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      child: Text('${_tags.indexOf(tag.key) + 1}',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.onPrimary)),
                    )
                  : null,
              selectedColor: Color.alphaBlend(
                  scheme.primary.withValues(alpha: .08),
                  CanteenTheme.surfaceBg(theme.brightness == Brightness.dark)),
              backgroundColor:
                  CanteenTheme.surfaceBg(theme.brightness == Brightness.dark),
              disabledColor:
                  CanteenTheme.surfaceBg(theme.brightness == Brightness.dark),
              side: BorderSide(
                  color: _tags.contains(tag.key)
                      ? scheme.primary
                      : scheme.outlineVariant),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              visualDensity: VisualDensity.standard,
              labelStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: _tags.contains(tag.key)
                      ? scheme.primary
                      : _saving || _tags.length >= 3
                          ? scheme.onSurface.withValues(alpha: .38)
                          : scheme.onSurface),
              onSelected:
                  _saving || (!_tags.contains(tag.key) && _tags.length >= 3)
                      ? null
                      : (value) => setState(() {
                            value ? _tags.add(tag.key) : _tags.remove(tag.key);
                          }),
            ),
        ]),
        const SizedBox(height: 12),
        Text('未选择时不显示评价标签',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    ]);
  }

  Widget _buildPage(BuildContext context) {
    context.watch<AuthProvider>();
    final provider = context.watch<CanteenProvider>();
    final valid = _sessionValid;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surface = CanteenTheme.surfaceBg(theme.brightness == Brightness.dark);
    final background = CanteenTheme.pageBg(theme.brightness == Brightness.dark);
    final canSave =
        valid && !_loading && _loadError == null && !_saving && _dirty;
    return PopScope(
      canPop: _leaving || !valid || (!_saving && !_dirty),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Form(
          key: _form,
          child: Scaffold(
            backgroundColor: AppPageBackground.color(context, background),
            appBar: AppBar(
              centerTitle: false,
              title: Text('编辑商家',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              backgroundColor: AppPageBackground.color(context, background),
            ),
            body: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1016),
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    child: LayoutBuilder(builder: (context, constraints) {
                      final editor = AppCardSurface(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                            color: surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: scheme.outlineVariant
                                    .withValues(alpha: .5))),
                        child: !valid
                            ? const CanteenFormNotice('账号或管理权限已变更，请返回后重新打开',
                                error: true)
                            : _loading
                                ? const Padding(
                                    padding: EdgeInsets.all(48),
                                    child: Center(
                                        child: CircularProgressIndicator()))
                                : _loadError != null
                                    ? CanteenEmptyState(
                                        title: '无法加载商家设置',
                                        subtitle: _loadError,
                                        actionLabel: '重试',
                                        onAction: _load)
                                    : _editorContent(provider),
                      );
                      if (!valid || _loading || _loadError != null) {
                        return editor;
                      }
                      if (constraints.maxWidth >= 820) {
                        return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: editor),
                              const SizedBox(width: 20),
                              SizedBox(width: 320, child: _merchantPreview()),
                            ]);
                      }
                      return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _merchantPreview(),
                            const SizedBox(height: 12),
                            editor,
                          ]);
                    }),
                  ),
                )),
            bottomNavigationBar: Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom),
              child: AppCardSurface(
                  color: surface,
                  child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        child: Center(
                            heightFactor: 1,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 976),
                              child: Row(children: [
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                      Text(
                                          !valid
                                              ? '当前不可编辑'
                                              : _loading
                                                  ? '正在加载资料'
                                                  : _dirty
                                                      ? '有未保存的修改'
                                                      : '未做修改',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                  fontWeight: FontWeight.w500)),
                                      const SizedBox(height: 3),
                                      Text('评价与菜品保留',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant)),
                                    ])),
                                const SizedBox(width: 16),
                                TextButton(
                                  key: const ValueKey('merchant-submit'),
                                  onPressed: canSave ? _save : null,
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(120, 44),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 18, vertical: 12),
                                    backgroundColor: scheme.primary,
                                    foregroundColor: scheme.onPrimary,
                                    disabledBackgroundColor: valid && _saving
                                        ? scheme.primary
                                        : scheme.surfaceContainerHighest,
                                    disabledForegroundColor: valid && _saving
                                        ? scheme.onPrimary
                                        : scheme.onSurface
                                            .withValues(alpha: .38),
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8)),
                                    textStyle: theme.textTheme.labelLarge,
                                  ).copyWith(
                                      visualDensity: VisualDensity.standard),
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (valid && _saving) ...[
                                          SizedBox.square(
                                              dimension: 16,
                                              child: CircularProgressIndicator(
                                                  color: scheme.onPrimary,
                                                  strokeWidth: 2)),
                                          const SizedBox(width: 8),
                                        ],
                                        Text(
                                            valid && _saving ? '保存中…' : '保存修改'),
                                      ]),
                                ),
                              ]),
                            )),
                      ))),
            ),
          )),
    );
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);
}
