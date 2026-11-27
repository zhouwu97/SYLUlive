import 'dart:io';
import 'package:flutter/material.dart';

typedef ThemeNavigationImages = Map<int, (ImageProvider, ImageProvider)>;

const originalThemeNavigationIconSize = 44.0;

ThemeNavigationImages themeNavigationImages(Map<String, dynamic>? navigation,
    {ImageProvider Function(String)? imageProvider}) {
  final icons = navigation?['icons'] as Map? ?? const {};
  ImageProvider load(String file) =>
      imageProvider?.call(file) ?? FileImage(File(file));
  return {
    for (final (index, slot)
        in ['home', 'market', 'schedule', 'campus', 'me'].indexed)
      if (icons[slot] != null)
        index: (
          load(icons[slot]['normal'] as String),
          load(icons[slot]['selected'] as String),
        ),
  };
}
