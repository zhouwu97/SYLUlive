import 'package:flutter/material.dart';

/// 全局颜色 token。
abstract final class AppColors {
  static const brandPrimary = Color(0xFF147C72);
  static const accentIndigo = Color(0xFF6366F1);
  static const accentPurple = Color(0xFF8B5CF6);
  static const accentPink = Color(0xFFEC4899);

  // Surface Tokens
  static const surfacePrimaryLight = Color(0xFFFFFAF4);
  static const surfaceSecondaryLight = Colors.white;
  static const surfaceMutedLight = Color(0xFFF2F3F1);
  static const surfaceFocusedLight = Color(0xFFEFF4F1);
  static const surfacePrimaryDark = Color(0xFF111315);
  static const surfaceSecondaryDark = Color(0xFF1A1D1F);
  static const surfaceMutedDark = Color(0xFF24282A);
  static const surfaceFocusedDark = Color(0xFF2B3033);

  // Text Tokens
  static const textPrimaryLight = Color(0xFF1F2328);
  static const textSecondaryLight = Color(0xFF747B82);
  static const textMutedLight = Color(0xFF858C89);
  static const textPrimaryDark = Color(0xFFF2F4F3);
  static const textSecondaryDark = Color(0xFFA7AFAB);

  // Border Tokens
  static const borderNormalLight = Color(0xFFE2EFEA);
  static const borderSubtleLight = Color(0xFFE8EEE9);
  static const borderNormalDark = Color(0xFF303638);
  static const borderSubtleDark = Color(0xFF252A2C);

  // Composer & Control Tokens
  static const composerSurfaceLight = Color(0xFFFFFFFF);
  static const composerSurfaceDark = Color(0xFF181B1D);
  static const composerInputLight = Color(0xFFF2F3F1);
  static const composerInputFocusedLight = Color(0xFFEFF4F1);
  static const composerInputDark = Color(0xFF24282A);
  static const composerInputFocusedDark = Color(0xFF2B3033);
  static const composerDividerLight = Color(0xFFE8EEE9);
  static const composerDividerDark = Color(0xFF303638);

  // Search Bar
  static const searchBarFillLight = Color(0xFFF1F2F0);
  static const searchBarFillDark = Color(0xFF24282A);

  // Chat Message Bubbles
  static const messageIncomingLight = Color(0xFFF0F1EF);
  static const messageIncomingBorderLight = Color(0xFFE2E5E1);
  static const messageIncomingDark = Color(0xFF262A2C);
  static const messageIncomingBorderDark = Color(0xFF323739);
  // Chat Message Bubbles & Send Button (Classic Sky Blue with high-contrast text)
  static const messageOutgoingLight = Color(0xFF76C4FF);
  static const messageOutgoingDark = Color(0xFF80C4FC);
  static const messageOutgoingTextLight = Color(0xFF1F2328);
  static const messageOutgoingTextDark = Color(0xFF111315);

  // Icons & Disabled States
  static const iconNeutralLight = Color(0xFF626966);
  static const iconNeutralDark = Color(0xFFB1B8B4);
  static const iconMutedLight = Color(0xFF858C89);
  static const iconMutedDark = Color(0xFF707874);
  static const disabledControlLight = Color(0xFFF2F3F1);
  static const disabledControlDark = Color(0xFF24282A);
  static const disabledControlTextLight = Color(0xFFB8BDBA);
  static const disabledControlTextDark = Color(0xFF5A615D);
}
