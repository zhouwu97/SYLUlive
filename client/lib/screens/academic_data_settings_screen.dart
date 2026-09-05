import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/academic/application/academic_login_coordinator.dart';
import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/presentation/academic_login_dialog.dart';
import '../features/academic/storage/academic_credential_store.dart';
import '../features/academic/storage/academic_persistence_policy.dart';
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
  AcademicPersistencePolicy? _policy;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _loadGeneration = 0;

  AcademicSessionController get _session =>
      context.read<AcademicSessionController>();

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
    final prefs = await AppPreferencesStore.getInstance();
    final preferences = AcademicStoragePreferences(
      appUserId: userId,
      store: prefs,
    );
    final credential = await PlatformAcademicCredentialStore().read(userId);
    final sourceAccountId =
        _session.studentId?.trim() ?? credential?.studentId ?? '';
    final vault = AesGcmAccountScopedSnapshotStore(appUserId: userId);
    final policy = AcademicPersistencePolicy(
      appUserId: userId,
      preferences: prefs,
      academicStore: AcademicCacheStore(
        appUserId: userId,
        sourceAccountId: sourceAccountId,
        snapshotStore: vault,
      ),
      scheduleStore: ScheduleCacheStore(
        appUserId: userId,
        sourceAccountId: sourceAccountId,
        snapshotStore: vault,
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
      _policy = policy;
      _loading = false;
    });
  }

  Future<void> _toggleCredentials(bool enabled) async {
    final preferences = _preferences;
    if (preferences == null) return;
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
        await PlatformAcademicCredentialStore().delete(preferences.appUserId);
        if (mounted) setState(() => _credential = null);
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('关闭本机教务资料保存？'),
        content: const Text('关闭后会删除本机保存的课表、成绩、学业情况和课程提醒，但不会删除教务登录凭据。'),
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

  Future<void> _clearData() async {
    final policy = _policy;
    if (policy == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final wasEnabled = policy.saveAcademicData;
      await policy.disableAndClear();
      if (wasEnabled) await policy.enable();
    } catch (_) {
      if (mounted) setState(() => _error = '本机教务资料清理失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _disconnectSession() async {
    await _session.resetSession();
    if (!mounted) return;
    context.read<EduProvider>().clearMemoryForAccountTransition();
    context.read<CourseScheduleProvider>().clearAllUserState();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已断开本次教务会话，凭据和本机资料仍保留')),
    );
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除本机教务账号？'),
        content: const Text('将删除教务凭据、课表、成绩和本机设置，不会删除沈理校园 App 账号。此操作不可恢复。'),
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
            child: const Text('删除本机教务账号'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final preferences = _preferences;
    final policy = _policy;
    setState(() => _saving = true);
    try {
      await _session.resetSession();
      if (!mounted) return;
      context.read<EduProvider>().clearMemoryForAccountTransition();
      context.read<CourseScheduleProvider>().clearAllUserState();
      if (preferences != null) {
        await PlatformAcademicCredentialStore().delete(preferences.appUserId);
        await policy?.academicStore?.clearAll();
        await policy?.scheduleStore?.clearAll();
        await AcademicPersistencePolicy.clearAuxiliaryData();
        await preferences.clear();
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = '删除本机教务账号失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _maskedStudentId() {
    final value = _credential?.studentId ?? _session.studentId ?? '';
    if (value.length <= 4) return value.isEmpty ? '未设置' : value;
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
        title: '本机教务',
        children: [
          Center(
              child: Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator()))
        ],
      );
    }
    final preferences = _preferences;
    final policy = _policy;
    final saveCredentials =
        preferences?.saveCredentials == true && _credential != null;
    final saveData = !kIsWeb &&
        preferences?.saveAcademicData == true &&
        policy?.cleanupPending != true;
    return SettingsPageScaffold(
      title: '本机教务',
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
          title: '本机教务',
          children: [
            SettingsTile(
              icon: Icons.school_outlined,
              title: '教务账号',
              subtitle: _maskedStudentId(),
              trailing: SettingsStatusBadge(
                label: _session.isAuthenticated ? '已连接' : '未连接',
                type: _session.isAuthenticated
                    ? SettingsStatusBadgeType.success
                    : SettingsStatusBadgeType.neutral,
              ),
              showChevron: false,
            ),
            SettingsTile(
              icon: Icons.key_outlined,
              title: '安全保存登录凭据',
              subtitle: kIsWeb ? '网页版不会保存教务密码' : '仅保存于本设备系统安全存储',
              trailing: Switch(
                value: kIsWeb ? false : saveCredentials,
                onChanged: kIsWeb || _saving ? null : _toggleCredentials,
              ),
              showChevron: false,
            ),
            SettingsTile(
              icon: Icons.lock_clock_outlined,
              title: '保存课表和成绩',
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
          title: '会话与资料',
          children: [
            SettingsTile(
              icon: Icons.link_off_outlined,
              title: '断开本次会话',
              subtitle: '清除学校 Cookie/Session，保留凭据和本机资料',
              onTap: _saving ? null : _disconnectSession,
            ),
            SettingsTile(
              icon: Icons.delete_sweep_outlined,
              title: '清除本机教务资料',
              subtitle: '清理课表、成绩、Profile、小组件和课程提醒',
              danger: true,
              onTap: _saving ? null : _clearData,
            ),
            SettingsTile(
              icon: Icons.person_remove_outlined,
              title: '删除本机教务账号',
              subtitle: '删除教务凭据、资料和保存设置，不删除 App 账号',
              danger: true,
              onTap: _saving ? null : _deleteAcademicAccount,
            ),
          ],
        ),
      ],
    );
  }
}
