import 'package:crypto/crypto.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../../widgets/settings/settings_page_scaffold.dart';
import '../application/emoji_recent_manager.dart';
import '../application/emoji_pack_installer.dart';
import '../data/emoji_pack_local_store.dart';
import '../data/emoji_pack_runtime.dart';
import '../domain/emoji_pack_installation.dart';
import 'emoji_download_screen.dart';

class EmojiManagementScreen extends StatefulWidget {
  const EmojiManagementScreen({super.key, this.store});
  final EmojiPackLocalStore? store;
  @override
  State<EmojiManagementScreen> createState() => _EmojiManagementScreenState();
}

class _EmojiManagementScreenState extends State<EmojiManagementScreen> {
  EmojiPackLocalStore? _store;
  List<EmojiPackInstallation>? _packs;
  Object? _error;
  bool _busy = false;
  int _storageBytes = 0;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    EmojiRecentManager.instance.addListener(_accountChanged);
    _accountId = EmojiRecentManager.instance.userId;
    _load();
  }

  String? _accountId;
  void _accountChanged() {
    final next = EmojiRecentManager.instance.userId;
    if (next == _accountId) return;
    _accountId = next;
    setState(() {
      _packs = null;
      _store = null;
    });
    _load();
  }

  @override
  void dispose() {
    EmojiRecentManager.instance.removeListener(_accountChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final store =
          widget.store ?? await EmojiPackRuntime.forAccount(_accountId);
      final packs = await store.load();
      final storageBytes = widget.store == null
          ? await store.storageBytes()
          : packs.fold<int>(0, (sum, pack) => sum + pack.totalSize);
      final audited = <EmojiPackInstallation>[];
      for (final pack in packs) {
        var damaged = false;
        for (final asset in pack.manifest.assets) {
          final file = File(
              '${store.versionDirectory(pack.packId, pack.version).path}/${asset.path}');
          if (!await file.exists() ||
              await file.length() != asset.fileSize ||
              (await sha256.bind(file.openRead()).first).toString() !=
                  asset.sha256.toLowerCase()) {
            damaged = true;
            break;
          }
        }
        if (damaged && pack.status != EmojiPackInstallStatus.damaged) {
          await store.exclusive(() => store
              .commit(pack.copyWith(status: EmojiPackInstallStatus.damaged)));
        }
        audited.add(damaged
            ? pack.copyWith(status: EmojiPackInstallStatus.damaged)
            : pack);
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _store = store;
        _packs = audited;
        _storageBytes = storageBytes;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                error is StateError ? error.message.toString() : '操作失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(EmojiPackInstallation pack) async {
    final store = _store!;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('删除本地安装？'),
                content: Text('将删除“${pack.name}”的本机文件，历史消息仍会保留。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (confirmed == true && mounted) {
      await _run(() => store.remove(pack.packId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final packs = _packs;
    return SettingsPageScaffold(title: '表情管理', onRefresh: _load, children: [
      ListTile(
          title: const Text('官方表情包'),
          leading: const Icon(Icons.download_outlined),
          trailing: const Icon(Icons.chevron_right),
          onTap: _store == null
              ? null
              : () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => EmojiDownloadScreen(store: _store!)));
                  if (mounted) await _load();
                }),
      if (_error != null)
        ListTile(
            title: const Text('读取表情包失败'),
            trailing: TextButton(onPressed: _load, child: const Text('重试')))
      else if (packs == null)
        const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()))
      else ...[
        ListTile(
            title: const Text('本地存储'),
            subtitle: Text(
                '${packs.length} 个表情包 · ${(_storageBytes / 1024 / 1024).toStringAsFixed(1)} MB')),
        if (packs.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('暂无已安装的表情包')),
        for (var i = 0; i < packs.length; i++) ...[
          ListTile(
              title: Text(packs[i].name),
              subtitle: Text(
                  'v${packs[i].version} · ${packs[i].manifest.assets.length} 个表情'
                  '${packs[i].status == EmojiPackInstallStatus.damaged ? ' · 文件损坏，请重新安装' : ''}'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) =>
                      EmojiPackDetailScreen(pack: packs[i], store: _store!))),
              trailing: Switch(
                  value: packs[i].enabled,
                  onChanged: _busy ||
                          packs[i].status == EmojiPackInstallStatus.damaged
                      ? null
                      : (value) => _run(
                          () => _store!.setEnabled(packs[i].packId, value)))),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                          await EmojiPackInstaller(_store!)
                              .rollback(packs[i].packId);
                        }),
                child: const Text('回滚')),
            IconButton(
                tooltip: '上移',
                onPressed: _busy || i == 0
                    ? null
                    : () {
                        final ids = packs.map((e) => e.packId).toList();
                        final previous = ids[i - 1];
                        ids[i - 1] = ids[i];
                        ids[i] = previous;
                        _run(() => _store!.reorder(ids));
                      },
                icon: const Icon(Icons.arrow_upward)),
            TextButton(
                onPressed: _busy ? null : () => _remove(packs[i]),
                child: const Text('删除本地安装')),
          ]),
          const Divider(),
        ],
      ],
    ]);
  }
}

class EmojiPackDetailScreen extends StatelessWidget {
  EmojiPackDetailScreen({super.key, required this.pack, required this.store})
      : _account = EmojiRecentManager.instance.userId;
  final String? _account;
  final EmojiPackInstallation pack;
  final EmojiPackLocalStore store;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: EmojiRecentManager.instance,
      builder: (context, _) => _account != EmojiRecentManager.instance.userId
          ? const SettingsPageScaffold(
              title: '表情详情', children: [ListTile(title: Text('账号已切换，请返回'))])
          : SettingsPageScaffold(title: pack.name, children: [
              ListTile(
                  title: Text('版本 ${pack.version}'),
                  subtitle: Text(pack.enabled ? '已启用' : '已禁用')),
              for (final asset in pack.manifest.assets)
                ListTile(
                    title: Text(asset.name),
                    leading: Image.file(
                        File(
                            '${store.versionDirectory(pack.packId, pack.version).path}/${asset.path}'),
                        width: 44,
                        height: 44,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image_outlined))),
            ]));
}
