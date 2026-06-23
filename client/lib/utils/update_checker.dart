import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

class UpdateChecker {
  /// 检查更新的核心方法
  /// [showNoUpdateToast] 设为 true 时，如果已经是最新版，可以给用户一个 Toast 提示（适合在“关于”页手动检查更新）
  static Future<void> check(BuildContext context,
      {bool showNoUpdateToast = false}) async {
    try {
      final dio = Dio();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      // 请求 Gitee 的 Latest Release 接口，附带时间戳防止 CDN 缓存
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

        // 获取本地版本号
        final packageInfo = await PackageInfo.fromPlatform();
        final String localVersion = packageInfo.version;

        // 对比版本号
        if (_hasNewVersion(localVersion, remoteVersion)) {
          // 检查是否包含强制更新标记
          final bool isForceUpdate = releaseNotes.contains('[force_update]');

          // 在 UI 上展示时，把标记字符串抹掉，避免用户看着奇怪
          final String displayNotes =
              releaseNotes.replaceAll('[force_update]', '').trim();

          if (!context.mounted) return;
          _showUpdateDialog(
              context, remoteVersion, displayNotes, downloadUrl, isForceUpdate);
        } else {
          if (showNoUpdateToast && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("当前已经是最新版本")),
            );
          }
        }
      }
    } catch (e) {
      debugPrint("检查更新失败: $e");
      // 静默处理，不打扰用户正常使用
    }
  }

  /// 简单的版本号比对逻辑 (假设格式为 v1.2.0 或 1.2.0)
  static bool _hasNewVersion(String local, String remote) {
    // 移除可能带有的 'v' 前缀
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

  /// 弹出更新对话框
  static void _showUpdateDialog(
    BuildContext context,
    String newVersion,
    String releaseNotes,
    String downloadUrl,
    bool isForceUpdate,
  ) {
    showDialog(
      context: context,
      // 如果是强制更新，点击背景不允许关闭
      barrierDismissible: !isForceUpdate,
      builder: (BuildContext context) {
        return PopScope(
          // 如果是强制更新，拦截物理返回键
          canPop: !isForceUpdate,
          child: AlertDialog(
            title: Text("发现新版本 $newVersion"),
            content: SingleChildScrollView(
              child: MarkdownBody(
                data: releaseNotes,
                selectable: true,
                styleSheet:
                    MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white70
                        : const Color(0xFF1F2937),
                  ),
                  tableHead: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white
                        : const Color(0xFF111827),
                  ),
                  tableBody: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white70
                        : const Color(0xFF111827),
                  ),
                  tableHeadAlign: TextAlign.left,
                  tablePadding: EdgeInsets.zero,
                  tableBorder: TableBorder(
                    top: BorderSide(
                      color: Theme.of(context)
                          .dividerColor
                          .withValues(alpha: 0.85),
                      width: 0.8,
                    ),
                    bottom: BorderSide(
                      color: Theme.of(context)
                          .dividerColor
                          .withValues(alpha: 0.85),
                      width: 0.8,
                    ),
                    horizontalInside: BorderSide(
                      color: Theme.of(context)
                          .dividerColor
                          .withValues(alpha: 0.55),
                      width: 0.8,
                    ),
                  ),
                  tableColumnWidth: const FlexColumnWidth(),
                  tableCellsPadding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                  tableCellsDecoration: const BoxDecoration(),
                  blockSpacing: 10,
                ),
              ),
            ),
            actions: <Widget>[
              // 非强制更新才显示“暂不更新”按钮
              if (!isForceUpdate)
                TextButton(
                  child: const Text("暂不更新"),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
              ElevatedButton(
                child: const Text("立即更新"),
                onPressed: () async {
                  final Uri url = Uri.parse(downloadUrl);
                  try {
                    bool launched = await launchUrl(url,
                        mode: LaunchMode.externalApplication);
                    if (!launched) {
                      launched = await launchUrl(url,
                          mode: LaunchMode.platformDefault);
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
                      // 复制到剪贴板
                      await Clipboard.setData(ClipboardData(text: downloadUrl));
                    }
                  }

                  // 如果不是强更，点击下载后关掉弹窗；如果是强更，弹窗就一直赖着不走
                  if (!isForceUpdate && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
