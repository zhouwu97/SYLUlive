import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UpdateChecker {
  static const String _ignoredUpdateVersionKey = 'ignored_update_version';
  static bool _dialogShowing = false;

  static Future<String?> _getIgnoredVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_ignoredUpdateVersionKey);
  }

  static Future<void> _ignoreVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ignoredUpdateVersionKey, version);
  }

  static Future<void> _clearIgnoredVersionIfChanged(String remoteVersion) async {
    final prefs = await SharedPreferences.getInstance();
    final ignored = prefs.getString(_ignoredUpdateVersionKey);
    if (ignored != null && ignored != remoteVersion) {
      await prefs.remove(_ignoredUpdateVersionKey);
    }
  }

  static Future<void> check(
    BuildContext context, {
    bool showNoUpdateToast = false,
    bool manual = false,
  }) async {
    try {
      final dio = Dio();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final response = await dio.get(
        'https://gitee.com/api/v5/repos/chunhezi/SYLUlive/releases/latest?t=$timestamp',
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data;
        final String remoteVersion = data['tag_name'] ?? '';
        final String releaseNotes = data['body'] ?? '暂无更新日志';
        String downloadUrl = data['html_url'] ?? '';
        if (data['assets'] != null && data['assets'] is List) {
          for (var asset in data['assets']) {
            final name = asset['name']?.toString().toLowerCase() ?? '';
            if (name.endsWith('.apk')) {
              downloadUrl = asset['browser_download_url'] ?? downloadUrl;
              break;
            }
          }
        }

        if (remoteVersion.isEmpty) return;

        final packageInfo = await PackageInfo.fromPlatform();
        final String localVersion = packageInfo.version;

        if (_hasNewVersion(localVersion, remoteVersion)) {
          final bool isForceUpdate = releaseNotes.contains('[force_update]');
          final String displayNotes = releaseNotes
              .replaceAll('[force_update]', '')
              .trim();

          if (!isForceUpdate && !manual) {
            final ignoredVersion = await _getIgnoredVersion();
            if (ignoredVersion == remoteVersion) {
              debugPrint('已忽略当前版本 $remoteVersion，自动检查不弹窗');
              return;
            }
          }

          await _clearIgnoredVersionIfChanged(remoteVersion);

          if (!context.mounted) return;
          if (_dialogShowing) return;

          _dialogShowing = true;
          await _showUpdateDialog(
            context,
            remoteVersion,
            displayNotes,
            downloadUrl,
            isForceUpdate,
          );
          _dialogShowing = false;
        } else {
          if (showNoUpdateToast && context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text("当前已经是最新版本")));
          }
        }
      }
    } catch (e) {
      debugPrint("检查更新失败: $e");
    }
  }

  static bool _hasNewVersion(String local, String remote) {
    String cleanLocal = local.replaceAll(RegExp(r'[^0-9.]'), '');
    String cleanRemote = remote.replaceAll(RegExp(r'[^0-9.]'), '');

    List<String> localParts = cleanLocal.split('.');
    List<String> remoteParts = cleanRemote.split('.');

    int length = localParts.length > remoteParts.length
        ? localParts.length
        : remoteParts.length;

    for (int i = 0; i < length; i++) {
      int l = i < localParts.length ? int.tryParse(localParts[i]) ?? 0 : 0;
      int r = i < remoteParts.length ? int.tryParse(remoteParts[i]) ?? 0 : 0;

      if (r > l) return true;
      if (r < l) return false;
    }
    return false;
  }

  static Future<void> _openDownloadUrl(
    BuildContext context,
    String downloadUrl,
  ) async {
    if (downloadUrl.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("下载链接为空，请稍后再试")),
        );
      }
      return;
    }
    final Uri url = Uri.parse(downloadUrl);
    try {
      bool launched = await launchUrl(
        url,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        launched = await launchUrl(
          url,
          mode: LaunchMode.platformDefault,
        );
      }
      if (!launched && context.mounted) {
        throw Exception("Could not launch url");
      }
    } catch (e) {
      debugPrint("唤起浏览器失败: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("唤起浏览器失败，已复制下载链接到剪贴板，请手动打开浏览器下载"),
            duration: Duration(seconds: 4),
          ),
        );
        await Clipboard.setData(ClipboardData(text: downloadUrl));
      }
    }
  }

  static Future<void> _showUpdateDialog(
    BuildContext context,
    String newVersion,
    String releaseNotes,
    String downloadUrl,
    bool isForceUpdate,
  ) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final bgColor = isDark ? const Color(0xFF1E2226) : Colors.white;
    final borderColor = isDark 
        ? Colors.white.withValues(alpha: 0.08) 
        : const Color(0xFFECE4DA);

    await showDialog(
      context: context,
      barrierDismissible: !isForceUpdate,
      builder: (BuildContext context) {
        return PopScope(
          canPop: !isForceUpdate,
          child: Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
            backgroundColor: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.system_update_rounded, color: primaryColor, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "发现新版本 $newVersion",
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "优化体验、修复问题，建议更新",
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark ? Colors.white60 : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (isForceUpdate) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, size: 16, color: const Color(0xFFF59E0B)),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              "该版本为必要更新，请更新后继续使用",
                              style: TextStyle(
                                fontSize: 13,
                                color: Color(0xFFF59E0B),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Container(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.38,
                    ),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFFFFAF4),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: borderColor),
                    ),
                    child: SingleChildScrollView(
                      child: MarkdownBody(
                        data: releaseNotes,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                            .copyWith(
                          p: TextStyle(
                            fontSize: 14,
                            height: 1.55,
                            color: isDark ? Colors.white70 : const Color(0xFF1F2937),
                          ),
                          tableHead: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white : const Color(0xFF111827),
                          ),
                          tableBody: TextStyle(
                            fontSize: 14,
                            height: 1.55,
                            color: isDark ? Colors.white70 : const Color(0xFF111827),
                          ),
                          tableHeadAlign: TextAlign.left,
                          tablePadding: EdgeInsets.zero,
                          tableBorder: TableBorder(
                            top: BorderSide(
                              color: Theme.of(context).dividerColor.withValues(alpha: 0.85),
                              width: 0.8,
                            ),
                            bottom: BorderSide(
                              color: Theme.of(context).dividerColor.withValues(alpha: 0.85),
                              width: 0.8,
                            ),
                            horizontalInside: BorderSide(
                              color: Theme.of(context).dividerColor.withValues(alpha: 0.55),
                              width: 0.8,
                            ),
                          ),
                          tableColumnWidth: const FlexColumnWidth(),
                          tableCellsPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 12,
                          ),
                          tableCellsDecoration: const BoxDecoration(),
                          blockSpacing: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (isForceUpdate)
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => _openDownloadUrl(context, downloadUrl),
                      child: const Text("立即更新", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                },
                                child: Text("稍后再说", style: TextStyle(color: isDark ? Colors.white70 : Colors.black54)),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () async {
                                  await _openDownloadUrl(context, downloadUrl);
                                  if (context.mounted) {
                                    Navigator.of(context).pop();
                                  }
                                },
                                child: const Text("立即更新", style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () async {
                            await _ignoreVersion(newVersion);
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          child: Text("忽略当前版本", style: TextStyle(fontSize: 13, color: isDark ? Colors.white38 : Colors.black38)),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
