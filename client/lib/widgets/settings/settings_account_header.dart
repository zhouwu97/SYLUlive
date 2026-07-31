import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../screens/account_security_screen.dart';
import '../../screens/login_screen.dart';
import '../campus/campus_theme.dart';
import '../cached_avatar.dart';

/// 设置页账号摘要卡片组件
class SettingsAccountHeader extends StatelessWidget {
  const SettingsAccountHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    final isLoggedIn = auth.isLoggedIn && auth.user != null;
    final user = auth.user;

    String title;
    String subtitle;
    String? avatarUrl;

    if (isLoggedIn && user != null) {
      title = user.nickname.trim().isNotEmpty
          ? user.nickname
          : (user.studentId.isNotEmpty ? user.studentId : '沈理用户');

      final List<String> details = [];
      if (user.studentId.trim().isNotEmpty) {
        details.add('学号 ${user.studentId.trim()}');
      }
      if (user.emailBound && user.emailMasked.trim().isNotEmpty) {
        details.add(user.emailMasked.trim());
      } else {
        details.add('未绑定邮箱');
      }

      subtitle = details.isNotEmpty ? details.join(' · ') : '完善账号信息';
      if (user.avatar.trim().isNotEmpty) {
        avatarUrl = ApiConstants.fullUrl(user.avatar.trim());
      }
    } else {
      title = '登录沈理校园';
      subtitle = '登录后管理账号和教务数据';
      avatarUrl = null;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkCard : CampusTheme.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : CampusTheme.softBorder,
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.025),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              if (isLoggedIn) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AccountSecurityScreen(),
                  ),
                );
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const LoginScreen(),
                  ),
                );
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: CachedAvatar(
                      imageUrl: avatarUrl,
                      radius: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : CampusTheme.text,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color:
                                isDark ? Colors.white60 : CampusTheme.subText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.3)
                        : CampusTheme.subText.withValues(alpha: 0.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
