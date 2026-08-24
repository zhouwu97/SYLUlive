import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../bottom_nav.dart';
import 'liquid_glass_runtime.dart';

/// 仅 Debug/Profile 开发包使用的 Liquid Glass 视觉 QA 页面。
///
/// 页面不改变业务导航，只把纹理背景和光学参数暴露出来，便于在真实
/// 模拟器/设备上先记录 Tier，再比较轮廓、折射和 Dock haze。
class LiquidGlassQaScreen extends StatefulWidget {
  const LiquidGlassQaScreen({super.key});

  @override
  State<LiquidGlassQaScreen> createState() => _LiquidGlassQaScreenState();
}

class _LiquidGlassQaScreenState extends State<LiquidGlassQaScreen> {
  late final ValueNotifier<double> _visualPosition;
  var _currentIndex = 2;
  var _tuning = const LiquidGlassTuning();

  @override
  void initState() {
    super.initState();
    _visualPosition = ValueNotifier(_currentIndex.toDouble());
  }

  @override
  void dispose() {
    _visualPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode) {
      return const Scaffold(
        body: Center(child: Text('Liquid Glass QA 仅在开发包可用')),
      );
    }

    final authProvider = context.read<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Liquid Glass QA')),
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const CustomPaint(painter: _LiquidGlassQaPatternPainter()),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 112),
                child: _buildControls(),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavWrapper(
        currentIndex: _currentIndex,
        visualIndexListenable: _visualPosition,
        onTap: (index) => _visualPosition.value = index.toDouble(),
        onNavigationCommitted: (index) {
          if (!mounted) return;
          setState(() => _currentIndex = index);
        },
        authProvider: authProvider,
        tuning: _tuning,
      ),
    );
  }

  Widget _buildControls() {
    return Card(
      color: Colors.black.withValues(alpha: 0.68),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '拖动底栏 Lens，观察首尾裁切、动态轮廓和文字折射。',
              style: TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text('Mode', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: LiquidGlassQaMode.values
                  .map(
                    (mode) => ChoiceChip(
                      label: Text(_modeLabel(mode)),
                      selected: _tuning.mode == mode,
                      onSelected: (_) => _setTuning(
                        _tuning.copyWith(mode: mode),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 6),
            _buildSlider(
              label: 'Refraction',
              value: _tuning.refraction,
              min: 0,
              max: 28,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(refraction: value),
              ),
            ),
            _buildSlider(
              label: 'Magnification',
              value: _tuning.magnification,
              min: 1,
              max: 1.14,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(magnification: value),
              ),
            ),
            _buildSlider(
              label: 'Chromatic',
              value: _tuning.chromatic,
              min: 0,
              max: 3,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(chromatic: value),
              ),
            ),
            _buildSlider(
              label: 'Rim',
              value: _tuning.rimStrength,
              min: 0,
              max: 2,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(rimStrength: value),
              ),
            ),
            _buildSlider(
              label: 'Light',
              value: _tuning.lightStrength,
              min: 0,
              max: 0.8,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(lightStrength: value),
              ),
            ),
            _buildSlider(
              label: 'Dock alpha',
              value: _tuning.dockAlpha,
              min: 0,
              max: 1,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(dockAlpha: value),
              ),
            ),
            _buildSlider(
              label: 'Dock blur',
              value: _tuning.dockBlur,
              min: 0,
              max: 14,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(dockBlur: value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 104,
          child: Text(
            '$label ${value.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  void _setTuning(LiquidGlassTuning tuning) {
    setState(() => _tuning = tuning);
  }

  String _modeLabel(LiquidGlassQaMode mode) {
    switch (mode) {
      case LiquidGlassQaMode.finalGlass:
        return 'Final';
      case LiquidGlassQaMode.identity:
        return 'Identity';
      case LiquidGlassQaMode.refractionOnly:
        return 'Refraction Only';
      case LiquidGlassQaMode.shapeOnly:
        return 'Shape Only';
    }
  }
}

class _LiquidGlassQaPatternPainter extends CustomPainter {
  const _LiquidGlassQaPatternPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2C1E4A), Color(0xFF0B6370), Color(0xFFF4A261)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, background);

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.22);
    for (var x = -size.height; x < size.width + size.height; x += 22) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), grid);
    }
    for (var y = 18.0; y < size.height; y += 36) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final blobs = Paint()..color = const Color(0x66FFFFFF);
    canvas.drawCircle(Offset(size.width * 0.18, size.height * 0.28), 76, blobs);
    canvas.drawCircle(
        Offset(size.width * 0.80, size.height * 0.46), 112, blobs);
    canvas.drawCircle(Offset(size.width * 0.48, size.height * 0.78), 58, blobs);
  }

  @override
  bool shouldRepaint(covariant _LiquidGlassQaPatternPainter oldDelegate) =>
      false;
}
