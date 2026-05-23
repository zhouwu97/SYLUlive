import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import 'app_feedback.dart';

class UpdateChecker {
  static Future<void> check(BuildContext context, {bool autoCheck = false}) async {
    const giteeUrl = 'https://gitee.com/chunhezi/SYLUlive/releases';
    const githubUrl = 'https://github.com/zhouwu97/SYLUlive/releases';
    try {
      final dio = context.read<AuthProvider>().dio;
      final packageInfo = await PackageInfo.fromPlatform();
      final resp = await dio.get('/version');
      if (resp.statusCode == 200) {
        final data = resp.data is Map ? resp.data as Map : <String, dynamic>{};
        final latestVersion = data['version']?.toString() ?? '';
        final minVersion = data['min_version']?.toString() ?? '';
        var forceUpdate = data['force_update'] ?? false;
        final currentVersion = packageInfo.version;

        if (minVersion.isNotEmpty && _isRemoteVersionNewer(minVersion, currentVersion)) {
          forceUpdate = true;
        }

        final giteeDownloadUrl =
            data['gitee_download_url']?.toString().trim().isNotEmpty == true
                ? data['gitee_download_url'].toString()
                : giteeUrl;
        final githubDownloadUrl =
            data['github_download_url']?.toString().trim().isNotEmpty == true
                ? data['github_download_url'].toString()
                : (data['download_url']?.toString().trim().isNotEmpty == true
                    ? data['download_url'].toString()
                    : githubUrl);
        final updateMsg = data['update_msg'] ?? '新版本可用';
        final hasUpdate =
            forceUpdate || _isRemoteVersionNewer(latestVersion, currentVersion);

        if (!hasUpdate && autoCheck) return;

        if (!context.mounted) return;
        showDialog(
          context: context,
          barrierDismissible: !forceUpdate,
          builder: (ctx) => PopScope(
            canPop: !forceUpdate,
            child: AlertDialog(
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(children: [
                Icon(
                  hasUpdate ? Icons.system_update : Icons.verified_outlined,
                  color: hasUpdate ? Colors.blue : Colors.green,
                ),
                const SizedBox(width: 8),
                Text(hasUpdate ? (forceUpdate ? '强制更新' : '发现新版本') : '已是最新版'),
              ]),
              content: Text(
                hasUpdate
                    ? '当前版本: $currentVersion\n最新版本: $latestVersion\n$updateMsg\n\n请选择下载来源。'
                    : '当前版本: $currentVersion\n服务器版本: ${latestVersion.isEmpty ? '未知' : latestVersion}\n当前已是最新版本。',
                style: const TextStyle(height: 1.5),
              ),
              actions: [
                if (!hasUpdate || !forceUpdate)
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(hasUpdate ? '稍后' : '关闭')),
                if (hasUpdate && forceUpdate)
                  TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        check(context, autoCheck: autoCheck); // 立马重新弹出
                      },
                      child: const Text('取消', style: TextStyle(color: Colors.grey))),
                if (hasUpdate)
                  OutlinedButton.icon(
                    onPressed: () {
                      if (!forceUpdate) Navigator.pop(ctx);
                      launchUrl(Uri.parse(giteeDownloadUrl),
                          mode: LaunchMode.externalApplication);
                    },
                    icon: const Icon(Icons.cloud_download_outlined, size: 18),
                    label: const Text('Gitee'),
                  ),
                if (hasUpdate)
                  ElevatedButton.icon(
                    onPressed: () {
                      if (!forceUpdate) Navigator.pop(ctx);
                      launchUrl(Uri.parse(githubDownloadUrl),
                          mode: LaunchMode.externalApplication);
                    },
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('GitHub'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white),
                  ),
              ],
            ),
          ),
        );
      }
    } on DioException catch (e) {
      if (!autoCheck && context.mounted) {
        AppFeedback.showSnackBar(
          context,
          AppFeedback.dioErrorMessage(e, fallback: '检查更新失败'),
          isError: true,
        );
      }
    } catch (e) {
      if (!autoCheck && context.mounted) {
        AppFeedback.showSnackBar(context, '检查更新失败: $e', isError: true);
      }
    }
  }

  static bool _isRemoteVersionNewer(String remote, String current) {
    final remoteParts = _parseVersion(remote);
    final currentParts = _parseVersion(current);
    final maxLength = remoteParts.length > currentParts.length
        ? remoteParts.length
        : currentParts.length;
    for (var i = 0; i < maxLength; i++) {
      final r = i < remoteParts.length ? remoteParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (r > c) return true;
      if (r < c) return false;
    }
    return false;
  }

  static List<int> _parseVersion(String version) {
    final normalized = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
    return normalized
        .split(RegExp(r'[.+-]'))
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
  }
}
