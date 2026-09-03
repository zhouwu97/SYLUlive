import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:package_info_plus/package_info_plus.dart';
import '../platform/contracts/external_navigator.dart';
import '../utils/update_checker.dart';
import 'group_chat_dialog.dart';

class AboutAppSheet extends StatefulWidget {
  const AboutAppSheet({super.key});

  @override
  State<AboutAppSheet> createState() => _AboutAppSheetState();
}

class _AboutAppSheetState extends State<AboutAppSheet> {
  String _currentVersion = '加载中...';
  static const String _pureHomozygoteEmail = '3170305904@qq.com';
  static const String _scoreDropperEmail = '2350016823@qq.com';
  static const String _nowEmail = '1517088507@qq.com';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _currentVersion = packageInfo.version;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 颜色令牌
    final pageBg = isDark ? const Color(0xFF101219) : const Color(0xFFFFFAF4);
    final cardBg = isDark ? const Color(0xFF1E2226) : Colors.white;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
    final accentSoft =
        isDark ? accent.withValues(alpha: 0.14) : const Color(0xFFEAF6F3);
    final border =
        isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE4DA);
    final text = isDark ? Colors.white : const Color(0xFF1F2328);
    final subText = isDark ? Colors.white70 : const Color(0xFF747B82);

    return FractionallySizedBox(
      heightFactor: 0.72,
      child: Container(
        decoration: BoxDecoration(
          color: pageBg,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(28),
            topRight: Radius.circular(28),
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // 拖拽指示条与关闭按钮
              Padding(
                padding: const EdgeInsets.only(top: 12, right: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(width: 48), // 占位保持居中
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: subText),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      // 顶部 Hero
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.asset(
                          'assets/images/mingfeng.png',
                          width: 64,
                          height: 64,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '沈理校园',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                          color: text,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '一款为沈理学生写的开源校园工具',
                        style: TextStyle(
                          fontSize: 13,
                          color: subText,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: accentSoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Version $_currentVersion',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),

                      // 版本信息卡
                      _buildSectionTitle('版本信息', text),
                      Container(
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: border),
                        ),
                        child: Column(
                          children: [
                            _buildInfoRow(
                                '当前版本', _currentVersion, text, subText,
                                height: 52),
                            Divider(
                                height: 1,
                                color: border,
                                indent: 16,
                                endIndent: 16),
                            InkWell(
                              onTap: () {
                                Navigator.pop(context);
                                UpdateChecker.check(context,
                                    showNoUpdateToast: true, manual: true);
                              },
                              borderRadius: const BorderRadius.only(
                                bottomLeft: Radius.circular(20),
                                bottomRight: Radius.circular(20),
                              ),
                              child: _buildActionRow('检查更新', text, subText,
                                  height: 52),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // 开发者卡片
                      _buildSectionTitle('开发者', text),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 16),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: border),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: accentSoft,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(Icons.code_rounded,
                                  size: 20, color: accent),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '纯合子、掉分员',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: text,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '用爱发电，写个自己觉得好用的课表和论坛。',
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.4,
                                      color: subText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // 相关链接列表
                      _buildSectionTitle('相关链接', text),
                      Container(
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: border),
                        ),
                        child: Column(
                          children: [
                            _buildLinkRow(
                              icon: Icons.device_hub_rounded,
                              iconColor: accent,
                              iconBg: accentSoft,
                              title: '开源仓库与源码',
                              text: text,
                              subText: subText,
                              border: border,
                              onTap: () => _launchUrl(
                                  'https://github.com/zhouwu97/SYLUlive'),
                            ),
                            Divider(
                                height: 1,
                                color: border,
                                indent: 56,
                                endIndent: 16),
                            _buildLinkRow(
                              icon: Icons.group_rounded,
                              iconColor: const Color(0xFF2F80ED),
                              iconBg: isDark
                                  ? const Color(0xFF2F80ED)
                                      .withValues(alpha: 0.14)
                                  : const Color(0xFF2F80ED)
                                      .withValues(alpha: 0.1),
                              title: '加入群聊',
                              text: text,
                              subText: subText,
                              border: border,
                              onTap: () => showGroupChatDialog(context),
                            ),
                            Divider(
                                height: 1,
                                color: border,
                                indent: 56,
                                endIndent: 16),
                            _buildLinkRow(
                              icon: Icons.email_rounded,
                              iconColor: const Color(0xFFF59E0B),
                              iconBg: isDark
                                  ? const Color(0xFFF59E0B)
                                      .withValues(alpha: 0.14)
                                  : const Color(0xFFF59E0B)
                                      .withValues(alpha: 0.1),
                              title: '联系作者',
                              text: text,
                              subText: subText,
                              border: border,
                              onTap: () => _showAuthorContactDialog(context),
                              isLast: true,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),

                      // 底部文案
                      Text(
                        'Made for SYLU students',
                        style: TextStyle(
                          fontSize: 12,
                          color: subText,
                        ),
                      ),
                      const SizedBox(height: 32),
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

  Widget _buildSectionTitle(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String title, String value, Color text, Color subText,
      {required double height}) {
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: TextStyle(fontSize: 15, color: text)),
            Text(value, style: TextStyle(fontSize: 14, color: subText)),
          ],
        ),
      ),
    );
  }

  Widget _buildActionRow(String title, Color text, Color subText,
      {required double height}) {
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: TextStyle(fontSize: 15, color: text)),
            Icon(Icons.chevron_right_rounded, color: subText, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildLinkRow({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required Color text,
    required Color subText,
    required Color border,
    required VoidCallback onTap,
    bool isLast = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: isLast
          ? const BorderRadius.only(
              bottomLeft: Radius.circular(20), bottomRight: Radius.circular(20))
          : BorderRadius.zero,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: TextStyle(fontSize: 15, color: text)),
              ),
              Icon(Icons.chevron_right_rounded, color: subText, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await ExternalNavigator.current().open(uri);
    } else {
      debugPrint('Could not launch URL: $url');
    }
  }

  void _showAuthorContactDialog(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBackground = isDark ? const Color(0xFF1E1E2E) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF2D3142);
    final labelColor = isDark ? Colors.white54 : const Color(0xFF9094A6);
    final descriptionColor = isDark ? Colors.white70 : const Color(0xFF4F5568);
    final valuePanelColor =
        isDark ? const Color(0x0AFFFFFF) : const Color(0x08000000);
    final valueBorderColor =
        isDark ? const Color(0x0DFFFFFF) : const Color(0x0D000000);
    const accent = Colors.orange;

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: dialogBackground,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              const Icon(Icons.email_rounded, color: accent),
              const SizedBox(width: 8),
              Text('联系作者', style: TextStyle(color: titleColor)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '作者邮箱',
                style: TextStyle(
                  fontSize: 13,
                  color: labelColor,
                ),
              ),
              const SizedBox(height: 10),
              _buildAuthorEmailRow(
                context: context,
                dialogContext: dialogContext,
                author: '纯合子',
                email: _pureHomozygoteEmail,
                titleColor: titleColor,
                labelColor: labelColor,
                panelColor: valuePanelColor,
                borderColor: valueBorderColor,
              ),
              const SizedBox(height: 10),
              _buildAuthorEmailRow(
                context: context,
                dialogContext: dialogContext,
                author: '掉分员',
                email: _scoreDropperEmail,
                titleColor: titleColor,
                labelColor: labelColor,
                panelColor: valuePanelColor,
                borderColor: valueBorderColor,
              ),
              const SizedBox(height: 10),
              _buildAuthorEmailRow(
                context: context,
                dialogContext: dialogContext,
                author: 'Now',
                email: _nowEmail,
                titleColor: titleColor,
                labelColor: labelColor,
                panelColor: valuePanelColor,
                borderColor: valueBorderColor,
              ),
              const SizedBox(height: 12),
              Text(
                '欢迎通过邮件反馈问题或提出建议。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: descriptionColor,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: accent),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),

          ],
        );
      },
    );
  }

  Widget _buildAuthorEmailRow({
    required BuildContext context,
    required BuildContext dialogContext,
    required String author,
    required String email,
    required Color titleColor,
    required Color labelColor,
    required Color panelColor,
    required Color borderColor,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.alternate_email_rounded,
            size: 18,
            color: Colors.orange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  author,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: labelColor,
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    email,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: titleColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '复制$author邮箱',
            onPressed: () =>
                _copyAuthorEmail(context, dialogContext, author, email),
            icon: const Icon(Icons.copy_rounded, size: 20),
            color: Colors.orange,
          ),
        ],
      ),
    );
  }

  Future<void> _copyAuthorEmail(
    BuildContext context,
    BuildContext dialogContext,
    String author,
    String email,
  ) async {
    await Clipboard.setData(ClipboardData(text: email));
    if (dialogContext.mounted) Navigator.pop(dialogContext);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$author的邮箱已复制到剪贴板'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}
