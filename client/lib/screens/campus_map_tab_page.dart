import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/campus_asset_preloader.dart';

class CampusMapTabPage extends StatefulWidget {
  const CampusMapTabPage({super.key});

  @override
  State<CampusMapTabPage> createState() => _CampusMapTabPageState();
}

class _CampusMapTabPageState extends State<CampusMapTabPage> {
  late final TransformationController _mapController;
  bool _isLandscape = false;

  @override
  void initState() {
    super.initState();
    _mapController = TransformationController();
  }

  @override
  void dispose() {
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _toggleLandscape() async {
    final useLandscape = !_isLandscape;
    await SystemChrome.setPreferredOrientations(
      useLandscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
    if (mounted) setState(() => _isLandscape = useLandscape);
  }

  void _resetMap() => _mapController.value = Matrix4.identity();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF111315) : const Color(0xFFFAF8F4);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('校园地图'),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: bgColor,
        surfaceTintColor: Colors.transparent,
        foregroundColor: isDark ? Colors.white : const Color(0xFF20212B),
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(
                    Icons.pinch_rounded,
                    size: 18,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '双指缩放 · 拖动查看',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: '复位地图',
                    child: IconButton(
                      onPressed: _resetMap,
                      icon: const Icon(Icons.restart_alt_rounded),
                    ),
                  ),
                  Tooltip(
                    message: _isLandscape ? '恢复竖屏' : '横屏查看',
                    child: IconButton(
                      onPressed: _toggleLandscape,
                      icon: Icon(
                        _isLandscape
                            ? Icons.stay_current_portrait_rounded
                            : Icons.stay_current_landscape_rounded,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E2226) : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : const Color(0xFFE2EFEA),
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) => InteractiveViewer(
                      transformationController: _mapController,
                      minScale: 1,
                      maxScale: 5,
                      panEnabled: true,
                      scaleEnabled: true,
                      boundaryMargin: const EdgeInsets.all(160),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: constraints.maxWidth,
                          child: Image(
                            image: CampusAssetPreloader.mapImage,
                            fit: BoxFit.contain,
                            alignment: Alignment.topCenter,
                            gaplessPlayback: true,
                            filterQuality: FilterQuality.medium,
                            frameBuilder: (context, child, frame, wasSync) {
                              if (wasSync || frame != null) {
                                return AnimatedOpacity(
                                  opacity: 1,
                                  duration: const Duration(milliseconds: 180),
                                  child: child,
                                );
                              }
                              return _MapLoadingPlaceholder(isDark: isDark);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MapLoadingPlaceholder extends StatelessWidget {
  const _MapLoadingPlaceholder({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 12908 / 7745,
      child: ColoredBox(
        color: isDark ? const Color(0xFF202529) : const Color(0xFFF1F5F3),
        child: const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
