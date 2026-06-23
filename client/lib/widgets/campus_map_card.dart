import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import 'glass_container.dart';

class CampusMapCard extends StatelessWidget {
  const CampusMapCard({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: GlassContainer(
        padding: EdgeInsets.zero,
        borderRadius: 16,
        blur: 15,
        opacity: themeProvider.componentOpacity.clamp(0.1, 0.3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图区域
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: Stack(
                children: [
                  SizedBox(
                    height: 180,
                    width: double.infinity,
                    child: Image.asset(
                      'assets/images/map.jpg',
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.3),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.map_outlined,
                              color: Colors.white, size: 14),
                          SizedBox(width: 4),
                          Text(
                            '校园全景',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 内容区域
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '沈理 Ligong Map',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.touch_app_outlined,
                        size: 18,
                        color: Theme.of(context)
                            .primaryColor
                            .withValues(alpha: 0.7),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '进入地图专属操控模式，支持高精度缩放与平移，助你快速找路。',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white60 : Colors.grey[700],
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.zoom_in_map_rounded, size: 20),
                      label: const Text(
                        '开启操控模式 (Precision Scale)',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      onPressed: () => _openMapControlMode(context),
                    ),
                  ),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  void _openMapControlMode(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black.withValues(alpha: 0.5),
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondaryAnimation) {
          return FadeTransition(
            opacity: animation,
            child: const MapControlFullscreenOverlay(),
          );
        },
      ),
    );
  }
}

class MapControlFullscreenOverlay extends StatefulWidget {
  const MapControlFullscreenOverlay({super.key});

  @override
  State<MapControlFullscreenOverlay> createState() =>
      _MapControlFullscreenOverlayState();
}

class _MapControlFullscreenOverlayState
    extends State<MapControlFullscreenOverlay> {
  final TransformationController _transformationController =
      TransformationController();

  void _zoom(double factor) {
    final Matrix4 matrix = _transformationController.value.clone();
    matrix.scale(factor);
    _transformationController.value = matrix;
  }

  void _reset() {
    _transformationController.value = Matrix4.identity();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    return PopScope(
      canPop: themeProvider.predictiveBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 地图缩放层
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _transformationController,
                minScale: 1.0,
                maxScale: 6.0,
                panAxis: PanAxis.free,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                child: Center(
                  child: Image.asset(
                    'assets/images/map.jpg',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),

            // 顶部返回按钮
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 16,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: GlassContainer(
                  padding: const EdgeInsets.all(10),
                  borderRadius: 50,
                  blur: 10,
                  opacity: 0.2,
                  child: const Icon(Icons.arrow_back_ios_new,
                      color: Colors.white, size: 20),
                ),
              ),
            ),

            // 底部 HUD
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 20,
              left: 16,
              right: 88,
              child: GlassContainer(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                borderRadius: 16,
                blur: 15,
                opacity: 0.2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.greenAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '地图操控模式已开启',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '双指捏合缩放，单指平移。右侧提供快捷比例控制。',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),

            // 右侧控制面板
            Positioned(
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildGlassButton(
                    icon: Icons.add_rounded,
                    onTap: () => _zoom(1.4),
                  ),
                  const SizedBox(height: 12),
                  _buildGlassButton(
                    icon: Icons.remove_rounded,
                    onTap: () => _zoom(1 / 1.4),
                  ),
                  const SizedBox(height: 12),
                  _buildGlassButton(
                    icon: Icons.restart_alt_rounded,
                    onTap: _reset,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlassButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: GlassContainer(
        width: 56,
        height: 56,
        padding: EdgeInsets.zero,
        borderRadius: 16,
        blur: 10,
        opacity: 0.2,
        child: Center(
          child: Icon(icon, color: Colors.white, size: 26),
        ),
      ),
    );
  }
}
