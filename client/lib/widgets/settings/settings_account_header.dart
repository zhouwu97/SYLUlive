import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../screens/account_security_screen.dart';
import '../../screens/login_screen.dart';
import '../campus/campus_theme.dart';
import '../cached_avatar.dart';
import 'settings_status_badge.dart';

/// 设置页账号摘要卡片组件 (恢复大气舒展样式)
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
    bool isStudentVerified = false;
    bool isEmailBound = false;

    if (isLoggedIn && user != null) {
      title = user.nickname.trim().isNotEmpty ? user.nickname.trim() : '沈理用户';
      isStudentVerified = user.studentVerified;
      isEmailBound = user.emailBound;

      final List<String> details = [];
      if (user.studentId.trim().isNotEmpty) {
        details.add(user.studentId.trim());
      } else {
        details.add('学号已保密');
      }

      if (user.eduMajor.trim().isNotEmpty) {
        details.add(user.eduMajor.trim());
      } else if (user.eduCollege.trim().isNotEmpty) {
        details.add(user.eduCollege.trim());
      } else {
        details.add('计算机科学与技术');
      }

      subtitle = details.join(' · ');
      if (user.avatar.trim().isNotEmpty) {
        avatarUrl = ApiConstants.fullUrl(user.avatar.trim());
      }
    } else {
      title = '登录沈理校园';
      subtitle = '登录后管理账号和教务数据';
      avatarUrl = null;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
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
                  blurRadius: 10,
                  offset: const Offset(0, 4),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 54,
                    height: 54,
                    child: CachedAvatar(
                      imageUrl: avatarUrl,
                      radius: 27,
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
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color:
                                isDark ? Colors.white60 : CampusTheme.subText,
                          ),
                        ),
                        if (isLoggedIn) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              SettingsStatusBadge(
                                label: isStudentVerified ? '学生已认证' : '未学生认证',
                                type: isStudentVerified
                                    ? SettingsStatusBadgeType.success
                                    : SettingsStatusBadgeType.neutral,
                              ),
                              const SizedBox(width: 6),
                              SettingsStatusBadge(
                                label: isEmailBound ? '邮箱已绑定' : '未绑定邮箱',
                                type: isEmailBound
                                    ? SettingsStatusBadgeType.success
                                    : SettingsStatusBadgeType.neutral,
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
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
