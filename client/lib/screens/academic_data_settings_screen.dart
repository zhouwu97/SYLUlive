import '../features/academic/domain/academic_provider.dart';
import '../features/academic/data/academic_identity_client.dart';
import 'dart:async';
import '../features/academic/application/academic_identity_lifecycle_coordinator.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/academic/application/academic_login_coordinator.dart';
import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/domain/academic_repository.dart';
import '../features/academic/presentation/academic_login_dialog.dart';
import '../features/academic/storage/academic_credential_store.dart';
import '../features/academic/storage/academic_persistence_policy.dart';
import '../features/academic/storage/academic_persistence_gate.dart';
import '../features/academic/storage/academic_storage_preferences.dart';
import '../features/campus_data/storage/academic_cache_store.dart';
import '../features/campus_data/storage/account_scoped_snapshot_store.dart';
import '../features/campus_data/storage/schedule_cache_store.dart';
import '../platform/contracts/preferences_store.dart';
import '../providers/auth_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../providers/edu_provider.dart';
import '../widgets/settings/settings_page_scaffold.dart';
import '../widgets/settings/settings_section.dart';
import '../widgets/settings/settings_status_badge.dart';
import '../widgets/settings/settings_tile.dart';

/// 本机教务凭据与资料的独立生命周期设置页。
final class AcademicDataSettingsScreen extends StatefulWidget {
  const AcademicDataSettingsScreen({super.key});

  @override
  State<AcademicDataSettingsScreen> createState() =>
      _AcademicDataSettingsScreenState();
}

class _AcademicDataSettingsScreenState
    extends State<AcademicDataSettingsScreen> {
  AcademicStoragePreferences? _preferences;
  AcademicCredential? _credential;
  bool _credentialStorageUnavailable = false;
  AcademicPersistencePolicy? _policy;
  List<AcademicIdentityBinding> _identities = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _loadGeneration = 0;

  AcademicSessionController get _session =>
      context.read<AcademicSessionController>();

  bool get _usesLocalCredentials =>
      _session.sourceKind == AcademicSourceKind.local;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loadGeneration = ++_loadGeneration;
    final auth = context.read<AuthProvider>();
    final userId = auth.user?.id.toString();
    if (userId == null || userId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final identities =
          await _session.providerRouter?.loadIdentityBindings(force: true) ??
              const <AcademicIdentityBinding>[];
      if (!mounted ||
          loadGeneration != _loadGeneration ||
          _session.appUserId != userId) {
        return;
      }
      _identities = identities;
      if (!_session.hasBoundIdentity && identities.isNotEmpty) {
        await _session
            .selectProviderIdentity(identities.first.toIdentity(userId));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '读取本机教务账号失败，请重试');
    }
    final prefs = await AppPreferencesStore.getInstance();
    final preferences = AcademicStoragePreferences(
      appUserId: userId,
      identity: _session.identity,
      store: prefs,
    );
    await preferences.migrateLegacyPreferences();
    final identity = _session.identity;
    if (identity != null) {
      try {
        await AcademicIdentityLifecycleCoordinator(
                controller: _session, preferences: prefs)
            .retryPending(identity);
      } catch (_) {
        if (mounted) setState(() => _error = '上次教务资料清理尚未完成，请重试清除');
      }
    }
    AcademicCredential? credential;
    var credentialStorageUnavailable = false;
    try {
      if (_usesLocalCredentials) {
        credential = await (_session.identity == null
            ? PlatformAcademicCredentialStore().read(userId)
            : PlatformAcademicCredentialStore()
                .readForIdentity(_session.identity!));
      }
    } catch (_) {
      credentialStorageUnavailable = true;
    }
    final sourceAccountId =
        _session.studentId?.trim() ?? credential?.studentId ?? '';
    final identityNamespace = _session.identity?.storageId;
    final vault = AesGcmAccountScopedSnapshotStore(
      appUserId: userId,
      identityNamespace: identityNamespace,
    );
    final policy = AcademicPersistencePolicy(
      appUserId: userId,
      identity: _session.identity,
      preferences: prefs,
      academicStore: AcademicCacheStore(
        appUserId: userId,
        sourceAccountId: sourceAccountId,
        identityNamespace: identityNamespace,
        snapshotStore: vault,
        persistenceGate: RegistryAcademicPersistenceGate(userId),
      ),
      scheduleStore: ScheduleCacheStore(
        appUserId: userId,
        sourceAccountId: sourceAccountId,
        identityNamespace: identityNamespace,
        snapshotStore: vault,
        persistenceGate: RegistryAcademicPersistenceGate(userId),
      ),
      auxiliaryCleanup: AcademicPersistencePolicy.clearAuxiliaryData,
      supported: !kIsWeb,
    );
    if (!mounted || loadGeneration != _loadGeneration) {
      await _closePolicy(policy);
      return;
    }
    final previousPolicy = _policy;
    await _closePolicy(previousPolicy);
    if (!mounted || loadGeneration != _loadGeneration) {
      await _closePolicy(policy);
      return;
    }
    setState(() {
      _preferences = preferences;
      _credential = credential;
      _credentialStorageUnavailable = credentialStorageUnavailable;
      _policy = policy;
      _loading = false;
    });
  }

  Future<void> _resolveConfig(AcademicProviderId provider,
      {required bool adopt}) async {
    final router = _session.providerRouter;
    if (router?.accountStore == null) return;
    setState(() => _saving = true);
    try {
      await router!.syncConfiguration();
      if (adopt) {
        final old = _session.identity;
        await router.accountStore!.adoptCloud(provider);
        if (old?.providerId == provider) {
          await _session.acceptIdentityUnbound(old!);
        }
      } else {
        await router.accountStore!.keepLocal(provider);
        unawaited(router.syncConfiguration());
      }
      if (mounted) await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '同步配置未完成，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _syncStatus(AcademicProviderId provider) {
    final e = _session.providerRouter?.accountStore?.entry(provider) ?? {};
    if (e['conflict'] == true) return '同步冲突';
    if (e['remote_changed'] == true) return '其他设备已修改';
    if ((e['outbox'] as List? ?? []).isNotEmpty) return '账号配置待同步';
    return e['snapshot'] == null ? '尚未同步' : '账号配置已同步';
  }

  String _maskIdentity(String value) => value.length < 5
      ? '****'
      : '${value.substring(0, 2)}****${value.substring(value.length - 2)}';

  Future<void> _selectIdentity(AcademicIdentityBinding binding) async {
    final user = _session.appUserId;
    if (user == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // 已有身份切换只修改本机选择，不请求身份验证或换绑。
      await _session.selectProviderIdentity(binding.toIdentity(user));
      await _coordinatorOrNull()?.ensureAuthenticated();
      if (mounted) await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '切换身份未完成，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _unbindIdentity() async {
    final identity = _session.identity;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('从账号中移除此教务配置？'),
              content:
                  const Text('立即移除此教务配置及本机资料，云端将在联网后同步。另一台离线设备的学校会话不会立即退出。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('移除配置')),
              ],
            ));
    if (confirmed != true || !mounted || _session.identity != identity) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await context.read<EduProvider>().unbind();
      if (!result.success) throw StateError(result.errorMessage ?? '解除失败');
      if (mounted) await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '移除配置未完成，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleCredentials(bool enabled) async {
    final preferences = _preferences;
    if (preferences == null || enabled && _credentialStorageUnavailable) return;
    final identity = _session.identity;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (enabled && _credential == null) {
        final loggedIn = await AcademicLoginDialog.show(
          context,
          controller: _session,
          coordinator: _coordinatorOrNull(),
          initialSaveCredentials: true,
        );
        if (loggedIn == true && mounted) await _load();
        return;
      }
      await preferences.setSaveCredentials(enabled);
      if (!enabled) {
        if (identity != null) {
          await PlatformAcademicCredentialStore().deleteForIdentity(identity);
        } else {
          await PlatformAcademicCredentialStore().delete(preferences.appUserId);
        }
        if (mounted) {
          setState(() {
            _credential = null;
            _credentialStorageUnavailable = false;
          });
        }
      }
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = '凭据保存设置失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleAcademicData(bool enabled) async {
    final policy = _policy;
    if (policy == null || kIsWeb) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (enabled) {
        await policy.enable();
      } else {
        await _confirmDisable(policy);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '本机教务资料清理失败，开关保持开启，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDisable(AcademicPersistencePolicy policy) async {
    final retainedData = _session.capabilities.supportsGrades
        ? '课表（含自定义课程、隐藏记录和存档）、成绩、学业情况和课程提醒'
        : '课表（含自定义课程、隐藏记录和存档）和课程提醒';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('关闭本机教务资料保存？'),
        content: Text('关闭后会删除本机$retainedData。此后课表修改不会在重启后保留；教务绑定和登录凭据不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认关闭并清除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await policy.disableAndClear();
  }

  Future<void> _clearData() => _deleteAcademicAccount();

  Future<void> _disconnectSession() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_session.connectionPreference !=
              AcademicConnectionPreference.connected ||
          !_session.isAuthenticated) {
        await _session.reconnect();
        if (!mounted) return;
        final coordinator = _coordinatorOrNull();
        final outcome = await coordinator?.ensureAuthenticated();
        if (!mounted) return;
        if (outcome != null && !outcome.isSuccess) {
          await AcademicLoginDialog.show(context,
              controller: _session, coordinator: coordinator);
        }
      } else {
        await _session.disconnect();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '本机教务连接操作未完成，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  AcademicLoginCoordinator? _coordinatorOrNull() {
    try {
      return context.read<AcademicLoginCoordinator>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _closePolicy(AcademicPersistencePolicy? policy) async {
    try {
      await policy?.close();
    } catch (_) {
      // 设置页刷新和退出不能被底层存储句柄清理异常阻断。
    }
  }

  Future<void> _deleteAcademicAccount() async {
    final retainedData = _session.capabilities.supportsGrades
        ? '教务凭据、课表、成绩和本机设置'
        : '教务凭据、课表和本机设置';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除本机教务资料？'),
        content: Text('将删除$retainedData、学校会话及其密钥，保留云端账号配置和 App 账号。此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final identity = _session.identity;
    if (identity == null) {
      setState(() => _error = '尚未确认教务身份，请恢复身份后重试');
      return;
    }
    setState(() => _saving = true);
    try {
      final lifecycle = AcademicIdentityLifecycleCoordinator(
        controller: _session,
        preferences: await AppPreferencesStore.getInstance(),
      );
      await _session.providerRouter?.accountStore
          ?.remove(identity.providerId, fromCloud: false);
      await lifecycle.clearLocalIdentity(identity);
      await _session.providerRouter?.accountStore?.acknowledgeCleanup(identity);
      await _session.acceptIdentityUnbound(identity);
      if (!mounted) return;
      context.read<EduProvider>().clearMemoryForAccountTransition();
      context.read<CourseScheduleProvider>().clearAllUserState();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = '删除本机教务账号失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _maskedStudentId() {
    final value = _credential?.studentId ?? _session.studentId ?? '';
    if (value.length <= 6) return value.isEmpty ? '未设置' : value;
    final hidden = List<String>.filled(value.length - 6, '*').join();
    return '${value.substring(0, 4)}$hidden${value.substring(value.length - 2)}';
  }

  @override
  void dispose() {
    _loadGeneration++;
    unawaited(_closePolicy(_policy));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SettingsPageScaffold(
        title: '教务账号与本机连接',
        children: [
          Center(
              child: Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator()))
        ],
      );
    }
    context.watch<AcademicSessionController>();
    final disconnected = _session.connectionPreference ==
        AcademicConnectionPreference.disconnected;
    final preferences = _preferences;
    final policy = _policy;
    final saveCredentials = preferences?.saveCredentials == true;
    final saveData = !kIsWeb &&
        preferences?.saveAcademicData == true &&
        policy?.cleanupPending != true;
    final supportsGrades = _session.capabilities.supportsGrades;
    final savedDataTitle = supportsGrades ? '保存课表和成绩' : '保存课表';
    final clearDataSubtitle = supportsGrades
        ? '删除密码、会话、课表、成绩及教务密钥，保留云端账号配置'
        : '删除密码、会话、课表及教务密钥，保留云端账号配置';
    return SettingsPageScaffold(
      title: '教务账号与本机连接',
      onRefresh: _load,
      children: [
        if (_error != null)
          SettingsSection(
            children: [
              SettingsTile(
                icon: Icons.error_outline,
                title: '操作未完成',
                subtitle: _error,
                danger: true,
                showChevron: false,
              ),
            ],
          ),
        SettingsSection(
          title: '教务账号与本机连接',
          children: [
            SettingsTile(
              icon: Icons.school_outlined,
              title: '教务账号',
              subtitle: _maskedStudentId(),
              trailing: SettingsStatusBadge(
                label: disconnected
                    ? '已断开'
                    : (_session.isAuthenticated ? '已连接' : '未连接'),
                type: _session.isAuthenticated
                    ? SettingsStatusBadgeType.success
                    : SettingsStatusBadgeType.neutral,
              ),
              showChevron: false,
            ),
            if (_usesLocalCredentials)
              SettingsTile(
                icon: Icons.key_outlined,
                title: '安全保存登录凭据',
                subtitle: kIsWeb
                    ? '网页版不会保存教务密码'
                    : _credentialStorageUnavailable
                        ? '本机安全存储暂不可用，请稍后重试'
                        : !saveCredentials
                            ? '已关闭密码保存'
                            : _session.providerId != null &&
                                    _session.providerRouter?.accountStore
                                            ?.rejected(_session.providerId!) ==
                                        true
                                ? '学校已拒绝保存的密码，请更新密码'
                                : _credential == null
                                    ? '此设备尚未保存密码'
                                    : '密码已安全保存在本设备',
                trailing: Switch(
                  value: kIsWeb ? false : saveCredentials,
                  onChanged: kIsWeb ||
                          _saving ||
                          _credentialStorageUnavailable && !saveCredentials
                      ? null
                      : _toggleCredentials,
                ),
                showChevron: false,
              ),
            SettingsTile(
              icon: Icons.lock_clock_outlined,
              title: savedDataTitle,
              subtitle: kIsWeb ? '网页版没有可用的本地加密保险箱' : '仅保存于当前 App 账号隔离的本地加密保险箱',
              trailing: Switch(
                value: saveData,
                onChanged: kIsWeb || _saving || policy == null
                    ? null
                    : _toggleAcademicData,
              ),
              showChevron: false,
            ),
          ],
        ),
        SettingsSection(
          title: '本机教务账号',
          children: [
            for (final binding in (_session
                    .providerRouter?.accountStore?.identities
                    .map((i) => AcademicIdentityBinding(
                        providerId: i.providerId,
                        studentId: i.studentId,
                        verified: false))
                    .toList() ??
                _identities))
              SettingsTile(
                icon: Icons.school_outlined,
                title: binding.providerId.displayName,
                subtitle: _maskIdentity(binding.studentId),
                trailing:
                    _session.identity == binding.toIdentity(_session.appUserId!)
                        ? const SettingsStatusBadge(
                            label: '当前使用',
                            type: SettingsStatusBadgeType.success)
                        : null,
                onTap: _saving ? null : () => _selectIdentity(binding),
              ),
            SettingsTile(
              icon: Icons.add,
              title: '添加教务账号',
              subtitle: '选择本科或研究生教务，在本设备登录',
              onTap: _saving
                  ? null
                  : () async {
                      await AcademicLoginDialog.show(context,
                          controller: _session,
                          coordinator: _coordinatorOrNull(),
                          addIdentity: true);
                      if (mounted) await _load();
                    },
            ),
            if (_session.hasBoundIdentity)
              SettingsTile(
                icon: Icons.person_remove_outlined,
                title: '从账号中移除此教务配置',
                subtitle: '移除此教务配置和本机资料，其他教务类型保留',
                danger: true,
                onTap: _saving ? null : _unbindIdentity,
              ),
          ],
        ),
        SettingsSection(
          title: '云端账号配置',
          children: [
            for (final provider in AcademicProviderId.values)
              SettingsTile(
                  icon: Icons.cloud_outlined,
                  title: provider.displayName,
                  subtitle: _syncStatus(provider),
                  onTap: _saving
                      ? null
                      : () async {
                          await _session.providerRouter?.syncConfiguration();
                          if (mounted) await _load();
                        }),
            for (final provider in AcademicProviderId.values)
              if (['同步冲突', '其他设备已修改'].contains(_syncStatus(provider))) ...[
                SettingsTile(
                    icon: Icons.phone_android,
                    title: '${provider.displayName}：保留本机配置',
                    subtitle: '将本机选择同步到账号',
                    onTap: _saving
                        ? null
                        : () => _resolveConfig(provider, adopt: false)),
                SettingsTile(
                    icon: Icons.cloud_download_outlined,
                    title: '${provider.displayName}：采用云端配置',
                    subtitle: '切换到云端学号，必要时输入该账号密码',
                    onTap: _saving
                        ? null
                        : () => _resolveConfig(provider, adopt: true)),
              ],
          ],
        ),
        SettingsSection(
          title: '会话与资料',
          children: [
            if (_session.hasBoundIdentity)
              SettingsTile(
                icon: Icons.manage_accounts_outlined,
                title: '更换教务学号',
                subtitle: '本机登录成功后更换学号，并清除旧账号本机资料',
                onTap: _saving
                    ? null
                    : () async {
                        await AcademicLoginDialog.show(context,
                            controller: _session,
                            coordinator: _coordinatorOrNull(),
                            changeIdentity: true);
                        if (mounted) await _load();
                      },
              ),
            if (_usesLocalCredentials)
              SettingsTile(
                icon: Icons.link_off_outlined,
                title: disconnected || !_session.isAuthenticated
                    ? '连接本机教务'
                    : '断开本机教务',
                subtitle:
                    disconnected ? '仍可查看已保存的本机数据' : '删除学校会话，保留凭据和资料，停止自动重连',
                onTap: _saving ? null : _disconnectSession,
              ),
            SettingsTile(
              icon: Icons.delete_sweep_outlined,
              title: '清除本机教务资料',
              subtitle: clearDataSubtitle,
              danger: true,
              onTap: _saving ? null : _clearData,
            ),
          ],
        ),
      ],
    );
  }
}
