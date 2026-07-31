import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../services/wallpaper_prefetch_service.dart';
import '../../../widgets/campus/campus_theme.dart';
import '../../../widgets/settings/campus_segmented_control.dart';

const List<String> phonePresetWallpaperAssets = [
  'morenbeijing.jpeg',
  'wallpaper_custom_01.png',
];

const List<String> landscapePresetWallpaperAssets = [
  'tablet_default_landscape.png',
  'tablet_landscape_01.png',
  'tablet_landscape_02.png',
  'tablet_landscape_03.png',
  'tablet_landscape_04.png',
  'tablet_landscape_05.png',
  'tablet_landscape_06.png',
  'tablet_landscape_08.png',
];

/// 背景选择底部面板
class BackgroundPickerSheet extends StatefulWidget {
  final bool initialIsLandscape;

  const BackgroundPickerSheet({
    super.key,
    this.initialIsLandscape = false,
  });

  static Future<void> show(BuildContext context, {bool isLandscape = false}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BackgroundPickerSheet(initialIsLandscape: isLandscape),
    );
  }

  @override
  State<BackgroundPickerSheet> createState() => _BackgroundPickerSheetState();
}

class _BackgroundPickerSheetState extends State<BackgroundPickerSheet> {
  late bool _isLandscape;

  @override
  void initState() {
    super.initState();
    _isLandscape = widget.initialIsLandscape;
  }

  String? _remoteWallpaperUrl(String assetName) {
    if (!assetName.startsWith('tablet_landscape_') &&
        !assetName.startsWith('phone_wallpaper_')) {
      return null;
    }
    return '${WallpaperPrefetchService.baseUrl}/$assetName';
  }

  String _wallpaperThumbnailAsset(String assetName) {
    return 'assets/images/wallpaper_thumbs/${path.basenameWithoutExtension(assetName)}.jpg';
  }

  String _backgroundPreviewAsset(String assetName) {
    if (_remoteWallpaperUrl(assetName) == null) {
      return ThemeProvider.resolveBundledAssetPath(assetName);
    }
    return _wallpaperThumbnailAsset(assetName);
  }

  Future<void> _setBackground(
    ThemeProvider themeProvider,
    bool isLandscape,
    String imagePath, {
    bool fillScreen = false,
  }) async {
    if (isLandscape) {
      await themeProvider.setLandscapeBackgroundImage(
        imagePath,
        fillScreen: fillScreen,
      );
    } else {
      await themeProvider.setBackgroundImage(imagePath, fillScreen: fillScreen);
    }
  }

  Future<String> _saveBackgroundFile(
    String sourcePath, {
    required bool isLandscape,
    required ThemeProvider themeProvider,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final ext = path.extension(sourcePath).isEmpty
        ? '.jpg'
        : path.extension(sourcePath);
    final fileName =
        '${isLandscape ? 'landscape_background' : 'background'}_${DateTime.now().millisecondsSinceEpoch}$ext';
    final savedPath = path.join(appDir.path, fileName);

    final bytes = await File(sourcePath).readAsBytes();
    await File(savedPath).writeAsBytes(bytes, flush: true);

    // 清理旧的本地自定义背景文件
    final oldPath = isLandscape
        ? themeProvider.landscapeBackgroundImage
        : themeProvider.backgroundImage;
    if (oldPath != null && ThemeProvider.isLocalFileBackground(oldPath)) {
      try {
        final oldFile = File(oldPath);
        if (await oldFile.exists()) {
          await oldFile.delete();
        }
      } catch (_) {}
    }

    return savedPath;
  }

  Future<void> _useBundledBackground(
    ThemeProvider themeProvider,
    String assetName,
    bool isLandscape,
  ) async {
    final remoteUrl = _remoteWallpaperUrl(assetName);
    if (remoteUrl == null) {
      await _setBackground(
        themeProvider,
        isLandscape,
        assetName,
        fillScreen: false,
      );
      return;
    }

    if (kIsWeb) {
      await _setBackground(
        themeProvider,
        isLandscape,
        remoteUrl,
        fillScreen: true,
      );
      return;
    }

    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      await _setBackground(
        themeProvider,
        isLandscape,
        _wallpaperThumbnailAsset(assetName),
        fillScreen: true,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('当前使用压缩预览图，登录后可自动下载高清壁纸'),
          ),
        );
      }
      return;
    }

    try {
      final savedPath = await WallpaperPrefetchService.localPathFor(assetName);
      await WallpaperPrefetchService.downloadAndVerifyImage(
        Dio(),
        remoteUrl,
        savedPath,
      );
      await _setBackground(
        themeProvider,
        isLandscape,
        savedPath,
        fillScreen: true,
      );
    } catch (e) {
      debugPrint('Download wallpaper failed: $e');
      await _setBackground(
        themeProvider,
        isLandscape,
        _wallpaperThumbnailAsset(assetName),
        fillScreen: true,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('高清壁纸下载失败，当前使用压缩预览图')),
        );
      }
    }
  }

  Future<void> _pickGalleryBackground(
    ThemeProvider themeProvider,
    bool isLandscape,
  ) async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    try {
      if (!mounted) return;
      final screenSize = MediaQuery.sizeOf(context);
      final isWideScreen = screenSize.width > screenSize.height;
      final targetRatioX = isLandscape
          ? (isWideScreen ? screenSize.width : 16.0)
          : (isWideScreen ? 9.0 : screenSize.width);
      final targetRatioY = isLandscape
          ? (isWideScreen ? screenSize.height : 9.0)
          : (isWideScreen ? 16.0 : screenSize.height);

      final cropped = await ImageCropper().cropImage(
        sourcePath: image.path,
        aspectRatio:
            CropAspectRatio(ratioX: targetRatioX, ratioY: targetRatioY),
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: '裁剪背景图片',
            toolbarColor: const Color(0xFF147C72),
            toolbarWidgetColor: Colors.white,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: true,
          ),
          IOSUiSettings(
            title: '裁剪背景图片',
            aspectRatioLockEnabled: true,
          ),
        ],
      );

      if (cropped == null) return;

      final savedPath = await _saveBackgroundFile(
        cropped.path,
        isLandscape: isLandscape,
        themeProvider: themeProvider,
      );

      await _setBackground(
        themeProvider,
        isLandscape,
        savedPath,
        fillScreen: true,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('Pick gallery background failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设置背景失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _confirmClearCurrentDirection(
      ThemeProvider themeProvider) async {
    final title = _isLandscape ? '删除横屏背景' : '删除竖屏背景';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text('确定要删除已保存的${_isLandscape ? '横屏' : '竖屏'}背景图片吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: CampusTheme.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (ok == true) {
      if (_isLandscape) {
        await themeProvider.setLandscapeBackgroundImage(null);
      } else {
        await themeProvider.setBackgroundImage(null);
      }
      if (!themeProvider.hasAnyBackground) {
        await themeProvider.setCleanBackgroundMode();
      }
    }
  }

  Future<void> _confirmClearAll(ThemeProvider themeProvider) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除全部背景'),
        content: const Text('确定要删除已保存的竖屏和横屏背景图片吗？删除后将自动切换为简洁模式。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: CampusTheme.red),
            child: const Text('删除全部'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await themeProvider.clearBackground();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final presets = _isLandscape
        ? landscapePresetWallpaperAssets
        : phonePresetWallpaperAssets;

    final currentBg = _isLandscape
        ? themeProvider.landscapeBackgroundImage
        : themeProvider.backgroundImage;

    final mediaWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = _isLandscape
        ? (mediaWidth >= 900 ? 4 : 3)
        : (mediaWidth >= 600 ? 4 : 3);
    final childAspectRatio = _isLandscape ? 16 / 9 : 9 / 16;

    final hasCurrentBg = _isLandscape
        ? themeProvider.hasLandscapeBackground
        : themeProvider.hasBackground;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkBg : CampusTheme.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white24
                    : CampusTheme.subText.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '背景图片',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : CampusTheme.text,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 采用平滑胶囊分段选择器 (100% 对齐外观页分段按钮)
          CampusSegmentedControl<bool>(
            items: const [
              CampusSegmentItem(
                value: false,
                label: '竖屏背景',
              ),
              CampusSegmentItem(
                value: true,
                label: '横屏背景',
              ),
            ],
            selectedValue: _isLandscape,
            onSelectionChanged: (selected) {
              setState(() {
                _isLandscape = selected;
              });
            },
          ),
          const SizedBox(height: 14),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: childAspectRatio,
                    ),
                    itemCount: presets.length,
                    itemBuilder: (context, index) {
                      final assetName = presets[index];
                      final previewAsset = _backgroundPreviewAsset(assetName);
                      final isSelected = currentBg == assetName ||
                          currentBg == _remoteWallpaperUrl(assetName);

                      return GestureDetector(
                        onTap: () async {
                          await _useBundledBackground(
                            themeProvider,
                            assetName,
                            _isLandscape,
                          );
                          if (context.mounted) Navigator.pop(context);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.asset(
                                previewAsset,
                                fit: _isLandscape
                                    ? BoxFit.cover
                                    : BoxFit.contain,
                                errorBuilder: (_, __, ___) => Container(
                                  color: isDark
                                      ? CampusTheme.darkCard
                                      : Colors.grey[200],
                                  child: const Icon(Icons.image_not_supported),
                                ),
                              ),
                              if (isSelected)
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: CampusTheme.primary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.check_rounded,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => _pickGalleryBackground(
                      themeProvider,
                      _isLandscape,
                    ),
                    icon: const Icon(Icons.photo_library_outlined, size: 20),
                    label: const Text('从相册选择图片'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      side: BorderSide(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.15)
                            : CampusTheme.softBorder,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  if (hasCurrentBg) ...[
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: () =>
                          _confirmClearCurrentDirection(themeProvider),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: Text('删除当前${_isLandscape ? "横屏" : "竖屏"}背景'),
                      style: TextButton.styleFrom(
                        foregroundColor: CampusTheme.red,
                      ),
                    ),
                  ],
                  if (themeProvider.hasAnyBackground) ...[
                    const SizedBox(height: 4),
                    TextButton.icon(
                      onPressed: () => _confirmClearAll(themeProvider),
                      icon:
                          const Icon(Icons.cleaning_services_rounded, size: 18),
                      label: const Text('删除全部背景并恢复简洁模式'),
                      style: TextButton.styleFrom(
                        foregroundColor: CampusTheme.red,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
