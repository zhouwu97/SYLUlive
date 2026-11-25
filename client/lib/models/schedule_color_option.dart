import 'package:flutter/material.dart';

enum ScheduleColorOption {
  theme('默认', null),
  dark('深色', Color(0xFF1F2937)),
  white('白色', Colors.white),
  blue('蓝色', Color(0xFF2563EB)),
  green('绿色', Color(0xFF15803D)),
  purple('紫色', Color(0xFF7E22CE)),
  orange('橙色', Color(0xFFC2410C));

  const ScheduleColorOption(this.label, this.color);
  final String label;
  final Color? color;

  static ScheduleColorOption fromStorage(String? value) {
    for (final option in values) {
      if (option.name == value) return option;
    }
    return theme;
  }
}
