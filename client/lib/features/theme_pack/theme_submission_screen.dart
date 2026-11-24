import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/idempotency_key.dart';
import '../../services/publish_session_scope.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_dialog.dart';
import 'theme_manifest.dart';
import 'theme_pack_codec.dart';
import 'theme_pack_store.dart';
import 'theme_store_repository.dart';

class ThemeSubmissionScreen extends StatefulWidget {
  const ThemeSubmissionScreen({
    super.key,
    this.initialPackageBytes,
    this.initialManifest,
    this.repository,
    this.pickFilePath,
    this.appVersion,
  });

  final Uint8List? initialPackageBytes;
  final ThemeManifest? initialManifest;
  final ThemeStoreRepository? repository;
  final Future<String?> Function()? pickFilePath;
  final String? appVersion;

  @override
  State<ThemeSubmissionScreen> createState() => _ThemeSubmissionScreenState();
}

class _ThemeSubmissionScreenState extends State<ThemeSubmissionScreen> {
  late TextEditingController _nameController;
  late TextEditingController _descController;
  final Set<String> _selectedTags = <String>{};
  String _license = 'CC-BY-4.0';
  String? _selectedFamilyId;
  bool _officialSource = false;
  bool _rightsConfirmed = false;

  Uint8List? _packageBytes;
  ThemeManifest? _manifest;

  late String _idempotencyKey;
  bool _submitting = false;
  bool _loadingFamilies = false;
  String? _errorMessage;
  List<ThemeSubmissionItem> _updatableFamilies = const [];

  int? _observedUserId;
  int? _observedEpoch;
  PublishSessionScope? _session;
  CancelToken? _familiesToken;

  String _lastName = '';
  String _lastDesc = '';

  ThemeStoreRepository _repo(AuthProvider auth) =>
      widget.repository ?? ThemeStoreRepository(auth.dio);

  @override
  void initState() {
    super.initState();
    _idempotencyKey = newIdempotencyKey('theme');
    _packageBytes = widget.initialPackageBytes;
    _manifest = widget.initialManifest;

    final initName = _manifest?.name ?? '';
    final initDesc = _manifest?.description ?? '';
    _lastName = initName;
    _lastDesc = initDesc;
    _nameController = TextEditingController(text: initName)
      ..addListener(_handleTextChanged);
    _descController = TextEditingController(text: initDesc)
      ..addListener(_handleTextChanged);

    final rawLic = _manifest?.data['license'] as String?;
    if (rawLic != null &&
        const ['CC0-1.0', 'CC-BY-4.0', 'CC-BY-NC-4.0', 'personal-use']
            .contains(rawLic)) {
      _license = rawLic;
    }
    final rawTags = _manifest?.data['tags'];
    if (rawTags is List) {
      for (final t in rawTags) {
        final s = t.toString();
        if (ThemeReviewReasons.allowedTags.contains(s) &&
            _selectedTags.length < 5) {
          _selectedTags.add(s);
        }
      }
    }
    if (_manifest == null && _packageBytes != null) {
      unawaited(_decodeInitialBytes(_packageBytes!));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (_observedUserId == auth.user?.id &&
        _observedEpoch == auth.accountSessionEpoch) {
      return;
    }
    _observedUserId = auth.user?.id;
    _observedEpoch = auth.accountSessionEpoch;
    _familiesToken?.cancel('会话已变更');
    _updatableFamilies = const [];
    _selectedFamilyId = null;
    if (auth.user?.isAdmin != true) {
      _officialSource = false;
    }
    _session = auth.isLoggedIn && auth.user != null
        ? PublishSessionScope(
            accountId: auth.user!.id,
            accountSessionEpoch: auth.accountSessionEpoch,
          )
        : null;
    if (_session != null) {
      unawaited(_loadExistingFamilies(auth, _session!));
    }
  }

  @override
  void dispose() {
    _familiesToken?.cancel('页面关闭');
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    if (_nameController.text != _lastName ||
        _descController.text != _lastDesc) {
      _lastName = _nameController.text;
      _lastDesc = _descController.text;
      _regenerateIdempotencyKey();
    }
  }

  void _regenerateIdempotencyKey() {
    _idempotencyKey = newIdempotencyKey('theme');
  }

  Future<String> _resolveAppVersion() async {
    if (widget.appVersion != null) return widget.appVersion!;
    try {
      return (await PackageInfo.fromPlatform())
          .version
          .split('+')
          .first
          .split('-')
          .first;
    } catch (_) {
      return '1.0.0';
    }
  }

  Future<void> _decodeInitialBytes(Uint8List bytes) async {
    try {
      final ver = await _resolveAppVersion();
      final prepared = await ThemePackCodec.decode(bytes, appVersion: ver);
      if (!mounted) return;
      _applyLoadedPack(bytes, prepared.manifest, resetKey: false);
    } on ThemePackError catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    }
  }

  void _applyLoadedPack(
    Uint8List bytes,
    ThemeManifest manifest, {
    bool resetKey = true,
  }) {
    setState(() {
      _packageBytes = bytes;
      _manifest = manifest;
      _errorMessage = null;
      _lastName = manifest.name;
      _lastDesc = manifest.description;
      _nameController.text = manifest.name;
      _descController.text = manifest.description;
      _selectedTags
        ..clear()
        ..addAll(
          ((manifest.data['tags'] as List?) ?? const [])
              .map((e) => e.toString())
              .where(ThemeReviewReasons.allowedTags.contains)
              .take(5),
        );
      final lic = manifest.data['license'] as String?;
      if (lic != null &&
          const ['CC0-1.0', 'CC-BY-4.0', 'CC-BY-NC-4.0', 'personal-use']
              .contains(lic)) {
        _license = lic;
      }
      if (resetKey) _regenerateIdempotencyKey();
    });
  }

  Future<void> _loadExistingFamilies(
    AuthProvider auth,
    PublishSessionScope session,
  ) async {
    final token = CancelToken();
    _familiesToken = token;
    setState(() => _loadingFamilies = true);
    try {
      final items = await _repo(auth).listMySubmissions(
        session: session,
        cancelToken: token,
      );
      if (!mounted ||
          token.isCancelled ||
          !session.owns(
            userId: auth.user?.id,
            sessionEpoch: auth.accountSessionEpoch,
          )) {
        return;
      }
      final byFamily = <String, ThemeSubmissionItem>{};
      for (final item in items) {
        if (item.status == 'removed' || item.status == 'withdrawn') continue;
        final existing = byFamily[item.familyId];
        if (existing == null || item.version > existing.version) {
          byFamily[item.familyId] = item;
        }
      }
      setState(() => _updatableFamilies = byFamily.values.toList());
    } catch (_) {
      // 新版本下拉加载失败不阻断首次投稿。
    } finally {
      if (mounted && !token.isCancelled) {
        setState(() => _loadingFamilies = false);
      }
    }
  }

  Future<void> _pickLocalSltheme() async {
    if (_submitting) return;
    try {
      String? filePath;
      if (widget.pickFilePath != null) {
        filePath = await widget.pickFilePath!();
      } else {
        final res = await FilePicker.platform.pickFiles(
          type: FileType.any,
          withData: false,
        );
        filePath = res?.files.single.path;
      }
      if (filePath == null || filePath.isEmpty) return;
      final bytes = await File(filePath).readAsBytes();
      final ver = await _resolveAppVersion();
      final prepared = await ThemePackCodec.decode(bytes, appVersion: ver);
      if (!mounted) return;
      _applyLoadedPack(bytes, prepared.manifest);
    } on ThemePackError catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (_) {
      if (mounted) setState(() => _errorMessage = '读取主题包文件失败，请重试。');
    }
  }

  Future<void> _pickFromInstalled() async {
    if (_submitting) return;
    final provider = context.read<ThemeProvider?>();
    if (provider == null) return;
    final installed = await provider.installedThemes();
    if (!mounted) return;
    if (installed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有已安装的本机主题')),
      );
      return;
    }
    final picked = await showModalBottomSheet<InstalledTheme>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AppCardSurface(
        decoration: BoxDecoration(
          color: Theme.of(ctx).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text(
                  '选择已安装主题',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              for (final item in installed)
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: Text(item.manifest.name),
                  subtitle:
                      Text('${item.manifest.author} · v${item.manifest.version}'),
                  onTap: () => Navigator.of(ctx).pop(item),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final bytes = await provider.themePacks.export(picked);
    if (!mounted) return;
    _applyLoadedPack(bytes, picked.manifest);
  }

  bool get _canSubmit =>
      !_submitting &&
      _session != null &&
      _packageBytes != null &&
      _rightsConfirmed &&
      _nameController.text.trim().isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final auth = context.read<AuthProvider>();
    final session = _session;
    if (session == null ||
        !session.owns(
          userId: auth.user?.id,
          sessionEpoch: auth.accountSessionEpoch,
        )) {
      setState(() => _errorMessage = '登录状态已变化，请重新打开投稿页。');
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final created = await _repo(auth).submit(
        packageBytes: _packageBytes!,
        idempotencyKey: _idempotencyKey,
        session: session,
        familyId: _selectedFamilyId,
        source: _officialSource ? 'official' : 'community',
        name: _nameController.text.trim(),
        description: _descController.text.trim(),
        tags: _selectedTags.toList(),
        license: _license,
        rightsConfirmed: _rightsConfirmed,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('《${created.name}》v${created.version} 已提交审核'),
        ),
      );
      unawaited(Navigator.of(context).maybePop(created));
    } on ThemeStoreApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'theme_quota') {
          _errorMessage =
              '投稿已达配额上限：最多同时保留 3 个待审核主题，且 24 小时内最多投稿 5 次。请等待审核或先撤回待审作品。';
        } else {
          _errorMessage = e.message;
        }
      });
    } on ThemeStoreDisabledException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } on PublishSessionChanged {
      if (mounted) setState(() => _errorMessage = '账号会话已变化，本次投稿已取消。');
    } catch (_) {
      if (mounted) setState(() => _errorMessage = '提交失败，请检查网络后重试（表单内容已保留）。');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final isAdmin = auth.user?.isAdmin == true;

    return Scaffold(
      appBar: AppBar(title: const Text('投稿主题')),
      body: !auth.isLoggedIn
          ? const Center(child: Text('请先登录后再投稿主题'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_errorMessage != null)
                      Container(
                        key: const ValueKey('theme-submit-error-banner'),
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    AppCard(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _manifest == null
                                  ? '尚未选择 .sltheme 主题包'
                                  : '当前包：${_manifest!.name} · ${ThemeReviewReasons.formatBytes(_packageBytes?.length ?? 0)}',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed:
                                      _submitting ? null : _pickLocalSltheme,
                                  icon: const Icon(Icons.folder_open_outlined),
                                  label: const Text('选择 .sltheme 文件'),
                                ),
                                OutlinedButton.icon(
                                  onPressed:
                                      _submitting ? null : _pickFromInstalled,
                                  icon: const Icon(Icons.inventory_2_outlined),
                                  label: const Text('从本机已安装选择'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    AppCard(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                          TextField(
                            key: const ValueKey('theme-submit-name'),
                            controller: _nameController,
                            enabled: !_submitting,
                            maxLength: 20,
                            decoration: const InputDecoration(
                              labelText: '主题名称（1–20 字）',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const ValueKey('theme-submit-description'),
                            controller: _descController,
                            enabled: !_submitting,
                            maxLength: 200,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              labelText: '主题简介（说明风格与适用场景，禁填外链/联系方式）',
                            ),
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: _license,
                            decoration: const InputDecoration(labelText: '素材许可'),
                            items: const [
                              DropdownMenuItem(
                                value: 'CC0-1.0',
                                child: Text('CC0-1.0（公共领域贡献）'),
                              ),
                              DropdownMenuItem(
                                value: 'CC-BY-4.0',
                                child: Text('CC-BY-4.0（署名共享）'),
                              ),
                              DropdownMenuItem(
                                value: 'CC-BY-NC-4.0',
                                child: Text('CC-BY-NC-4.0（署名-非商业）'),
                              ),
                              DropdownMenuItem(
                                value: 'personal-use',
                                child: Text('personal-use（仅供用户本机使用）'),
                              ),
                            ],
                            onChanged: _submitting
                                ? null
                                : (val) {
                                    if (val == null || val == _license) return;
                                    setState(() {
                                      _license = val;
                                      _regenerateIdempotencyKey();
                                    });
                                  },
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String?>(
                            key: const ValueKey('theme-submit-family-dropdown'),
                            initialValue: _selectedFamilyId,
                            decoration: InputDecoration(
                              labelText: _loadingFamilies
                                  ? '版本归属（加载中…）'
                                  : '版本归属',
                            ),
                            items: [
                              const DropdownMenuItem<String?>(
                                value: null,
                                child: Text('作为全新作品发布（v1）'),
                              ),
                              for (final fam in _updatableFamilies)
                                DropdownMenuItem<String?>(
                                  value: fam.familyId,
                                  child: Text(
                                    '作为《${fam.name}》的新版本（当前 v${fam.version}）',
                                  ),
                                ),
                            ],
                            onChanged: _submitting
                                ? null
                                : (val) {
                                    if (val == _selectedFamilyId) return;
                                    setState(() {
                                      _selectedFamilyId = val;
                                      _regenerateIdempotencyKey();
                                    });
                                  },
                          ),
                          if (isAdmin) ...[
                            const SizedBox(height: 8),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('作为官方主题发布 (official)'),
                              subtitle: const Text('仅管理员可用，进入商城“官方主题”专区'),
                              value: _officialSource,
                              onChanged: _submitting
                                  ? null
                                  : (val) => setState(() {
                                        _officialSource = val;
                                        _regenerateIdempotencyKey();
                                      }),
                            ),
                          ],
                          const SizedBox(height: 12),
                          const Text(
                            '标签（最多选择 5 个）',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final tag in ThemeReviewReasons.allowedTags)
                                FilterChip(
                                  label: Text(tag),
                                  selected: _selectedTags.contains(tag),
                                  onSelected: _submitting
                                      ? null
                                      : (sel) {
                                          setState(() {
                                            if (sel) {
                                              if (_selectedTags.length < 5) {
                                                _selectedTags.add(tag);
                                                _regenerateIdempotencyKey();
                                              }
                                            } else {
                                              _selectedTags.remove(tag);
                                              _regenerateIdempotencyKey();
                                            }
                                          });
                                        },
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          CheckboxListTile(
                            key: const ValueKey('theme-submit-rights-checkbox'),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _rightsConfirmed,
                            onChanged: _submitting
                                ? null
                                : (val) => setState(
                                      () => _rightsConfirmed = val ?? false,
                                    ),
                            title: const Text('我拥有全部素材的使用权'),
                            subtitle: const Text(
                              '确认壁纸、贴纸、图标与字体均符合授权要求，不含未授权商业插画或他人隐私信息',
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            key: const ValueKey('theme-submit-button'),
                            onPressed: _canSubmit ? _submit : null,
                            child: Text(_submitting ? '正在上传…' : '提交审核'),
                          ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class MyThemeSubmissionsScreen extends StatefulWidget {
  const MyThemeSubmissionsScreen({
    super.key,
    this.repository,
  });

  final ThemeStoreRepository? repository;

  @override
  State<MyThemeSubmissionsScreen> createState() =>
      _MyThemeSubmissionsScreenState();
}

class _MyThemeSubmissionsScreenState extends State<MyThemeSubmissionsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<ThemeSubmissionItem> _items = const [];
  bool _loading = false;
  bool _busyAction = false;
  String? _error;

  int? _observedUserId;
  int? _observedEpoch;
  PublishSessionScope? _session;
  int _loadGeneration = 0;
  CancelToken? _cancelToken;

  ThemeStoreRepository _repo(AuthProvider auth) =>
      widget.repository ?? ThemeStoreRepository(auth.dio);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (_observedUserId == auth.user?.id &&
        _observedEpoch == auth.accountSessionEpoch) {
      return;
    }
    _observedUserId = auth.user?.id;
    _observedEpoch = auth.accountSessionEpoch;
    _cancelToken?.cancel('切换账号清空列表');
    _loadGeneration++;
    // 切换账号、退出登录或同账号重登时立即清空列表，防止跨会话残留。
    _items = const [];
    _error = null;
    _session = auth.isLoggedIn && auth.user != null
        ? PublishSessionScope(
            accountId: auth.user!.id,
            accountSessionEpoch: auth.accountSessionEpoch,
          )
        : null;
    if (_session != null) {
      unawaited(_load());
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel('页面销毁');
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final auth = context.read<AuthProvider>();
    final session = _session;
    if (session == null ||
        !session.owns(
          userId: auth.user?.id,
          sessionEpoch: auth.accountSessionEpoch,
        )) {
      return;
    }
    final generation = ++_loadGeneration;
    _cancelToken?.cancel('刷新替换');
    final token = CancelToken();
    _cancelToken = token;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final loaded = await _repo(auth).listMySubmissions(
        session: session,
        cancelToken: token,
      );
      if (!mounted ||
          token.isCancelled ||
          generation != _loadGeneration ||
          !session.owns(
            userId: auth.user?.id,
            sessionEpoch: auth.accountSessionEpoch,
          )) {
        return;
      }
      setState(() => _items = loaded);
    } catch (e) {
      if (!mounted ||
          token.isCancelled ||
          generation != _loadGeneration ||
          !session.owns(
            userId: auth.user?.id,
            sessionEpoch: auth.accountSessionEpoch,
          )) {
        return;
      }
      setState(() => _error = '加载投稿记录失败，请重试');
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _withdraw(ThemeSubmissionItem item) async {
    if (_busyAction) return;
    final auth = context.read<AuthProvider>();
    final session = _session;
    if (session == null) return;

    final isApproved = item.status == 'approved';
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text('撤回《${item.name}》v${item.version}？'),
        content: Text(
          isApproved
              ? '该版本已上架，撤回后整个作品将从商城下线且所有历史版本停止下载。'
              : '撤回后该待审版本将不再进入审核。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认撤回'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyAction = true);
    try {
      await _repo(auth).withdrawSubmission(item.id, session: session);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  List<ThemeSubmissionItem> _filtered(int tabIndex) {
    return switch (tabIndex) {
      0 => _items.where((e) => e.status == 'pending').toList(),
      1 => _items.where((e) => e.status == 'approved').toList(),
      2 => _items.where((e) => e.status == 'rejected').toList(),
      _ => _items
          .where(
            (e) =>
                e.status == 'withdrawn' ||
                e.status == 'removed' ||
                e.status == 'superseded',
          )
          .toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的主题投稿'),
        actions: [
          if (auth.isLoggedIn)
            TextButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ThemeSubmissionScreen(
                      repository: widget.repository,
                    ),
                  ),
                );
                if (mounted && _session != null) await _load();
              },
              icon: const Icon(Icons.upload_outlined, size: 18),
              label: const Text('新投稿'),
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '待审核'),
            Tab(text: '已上架'),
            Tab(text: '未通过'),
            Tab(text: '已撤回'),
          ],
        ),
      ),
      body: !auth.isLoggedIn
          ? const Center(child: Text('请登录后查看我的主题投稿'))
          : _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        for (var tab = 0; tab < 4; tab++)
                          RefreshIndicator(
                            onRefresh: _load,
                            child: _buildTabList(_filtered(tab)),
                          ),
                      ],
                    ),
    );
  }

  Widget _buildTabList(List<ThemeSubmissionItem> list) {
    if (list.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          Center(child: Text('暂无对应状态的主题投稿')),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(14),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = list[index];
        final canWithdraw =
            item.status == 'pending' || item.status == 'approved';
        final statusLabel = switch (item.status) {
          'pending' => '待审核',
          'approved' => '已上架',
          'rejected' => '未通过',
          'withdrawn' => '已撤回',
          'removed' => '已下架',
          'superseded' => '已被新版取代',
          _ => item.status,
        };
        return AppCard(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${item.name} · v${item.version}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(statusLabel),
                  ),
                ],
              ),
              if (item.description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(item.description, style: const TextStyle(fontSize: 13)),
              ],
              if (item.reasonMessage.isNotEmpty &&
                  (item.status == 'rejected' || item.status == 'removed')) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${item.status == 'removed' ? '下架原因' : '未通过原因'}：${item.reasonMessage}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
              if (canWithdraw) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    onPressed: _busyAction ? null : () => _withdraw(item),
                    child: const Text('撤回'),
                  ),
                ),
              ],
              ],
            ),
          ),
        );
      },
    );
  }
}
