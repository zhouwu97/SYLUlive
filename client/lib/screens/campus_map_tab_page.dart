import 'package:flutter/material.dart';

class CampusMapTabPage extends StatefulWidget {
  const CampusMapTabPage({super.key});

  @override
  State<CampusMapTabPage> createState() => _CampusMapTabPageState();
}

class _CampusMapTabPageState extends State<CampusMapTabPage> {
  late final TransformationController _mapController;

  @override
  void initState() {
    super.initState();
    _mapController = TransformationController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    precacheImage(const AssetImage('assets/images/map.jpg'), context);
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E2226) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFFE2EFEA),
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
            child: InteractiveViewer(
              transformationController: _mapController,
              minScale: 0.7,
              maxScale: 5.0,
              panEnabled: true,
              scaleEnabled: true,
              boundaryMargin: const EdgeInsets.all(160),
              child: Center(
                child: Image.asset(
                  'assets/images/map.jpg',
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
