import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../bottom_nav.dart';
import 'liquid_glass_runtime.dart';

enum LiquidGlassQaPattern { horizontal, vertical, checker, text }

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
  var _pattern = LiquidGlassQaPattern.checker;
  var _qaPhase = LiquidNavPhase.idle;
  var _qaActivation = 0.0;

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
          CustomPaint(painter: _LiquidGlassQaPatternPainter(_pattern)),
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
        qaPhase: _qaPhase,
        qaActivation: _qaActivation,
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
              '拖动底栏 Lens，先看 Identity，再逐项打开光学效果。红框是 capture rect，青框是 Capsule 可见曲面。',
              style: TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text('Preset', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildQaChip(
                  'Natural',
                  _isPreset(LiquidGlassTuning.natural),
                  () => _setPreset(LiquidGlassTuning.natural),
                ),
                _buildQaChip(
                  'Coolapk',
                  _isPreset(LiquidGlassTuning.coolapk),
                  () => _setPreset(LiquidGlassTuning.coolapk),
                ),
                _buildQaChip(
                  'Strong',
                  _isPreset(LiquidGlassTuning.strong),
                  () => _setPreset(LiquidGlassTuning.strong),
                ),
              ],
            ),
            const SizedBox(height: 6),
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
            const Text('Color preset', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: LiquidNavColorPreset.values
                  .map(
                    (preset) => _buildQaChip(
                      _colorPresetLabel(preset),
                      _tuning.colorPreset == preset,
                      () => _setTuning(
                        _tuning.copyWith(colorPreset: preset),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 6),
            const Text(
              'Interaction state',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildQaChip(
                  'Idle',
                  _qaPhase == LiquidNavPhase.idle,
                  () => _setQaPhase(LiquidNavPhase.idle, 0),
                ),
                _buildQaChip(
                  'Pressed 25%',
                  _qaPhase == LiquidNavPhase.pressing && _qaActivation == 0.25,
                  () => _setQaPhase(LiquidNavPhase.pressing, 0.25),
                ),
                _buildQaChip(
                  'Pressed 50%',
                  _qaPhase == LiquidNavPhase.pressing && _qaActivation == 0.50,
                  () => _setQaPhase(LiquidNavPhase.pressing, 0.50),
                ),
                _buildQaChip(
                  'Pressed 100%',
                  _qaPhase == LiquidNavPhase.pressing && _qaActivation == 1,
                  () => _setQaPhase(LiquidNavPhase.pressing, 1),
                ),
                _buildQaChip(
                  'Dragging',
                  _qaPhase == LiquidNavPhase.dragging,
                  () => _setQaPhase(LiquidNavPhase.dragging, 1),
                ),
                _buildQaChip(
                  'Settling',
                  _qaPhase == LiquidNavPhase.settling,
                  () => _setQaPhase(LiquidNavPhase.settling, 1),
                ),
                _buildQaChip(
                  'Collapsing',
                  _qaPhase == LiquidNavPhase.collapsing,
                  () => _setQaPhase(LiquidNavPhase.collapsing, 0.55),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text('Pattern', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: LiquidGlassQaPattern.values
                  .map(
                    (pattern) => _buildQaChip(
                      _patternLabel(pattern),
                      _pattern == pattern,
                      () => setState(() => _pattern = pattern),
                    ),
                  )
                  .toList(),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                'Show capture bounds',
                style: TextStyle(color: Colors.white),
              ),
              value: _tuning.showCaptureBounds,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(showCaptureBounds: value),
              ),
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
              label: 'Pressed scale',
              value: _tuning.pressedScale,
              min: 1,
              max: 1.45,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(pressedScale: value),
              ),
            ),
            _buildSlider(
              label: 'Vertical scale',
              value: _tuning.verticalRefractionScale,
              min: 0.08,
              max: 0.70,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(verticalRefractionScale: value),
              ),
            ),
            _buildSlider(
              label: 'Overscan X',
              value: _tuning.overscanX,
              min: 12,
              max: 40,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(overscanX: value),
              ),
            ),
            _buildSlider(
              label: 'Overscan Y',
              value: _tuning.overscanY,
              min: 8,
              max: 32,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(overscanY: value),
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

  Widget _buildQaChip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }

  bool _isPreset(LiquidGlassTuning preset) {
    return _tuning.pressedScale == preset.pressedScale &&
        _tuning.refraction == preset.refraction &&
        _tuning.chromatic == preset.chromatic &&
        _tuning.colorPreset == preset.colorPreset;
  }

  void _setPreset(LiquidGlassTuning preset) {
    _setTuning(
      preset.copyWith(
        mode: _tuning.mode,
        showCaptureBounds: _tuning.showCaptureBounds,
      ),
    );
  }

  void _setTuning(LiquidGlassTuning tuning) {
    setState(() => _tuning = tuning);
  }

  void _setQaPhase(LiquidNavPhase phase, double activation) {
    setState(() {
      _qaPhase = phase;
      _qaActivation = activation;
    });
  }

  String _modeLabel(LiquidGlassQaMode mode) {
    switch (mode) {
      case LiquidGlassQaMode.finalGlass:
        return 'Final';
      case LiquidGlassQaMode.identity:
        return 'Identity';
      case LiquidGlassQaMode.coreOnly:
        return 'Core Only';
      case LiquidGlassQaMode.refractionOnly:
        return 'Refraction Only';
      case LiquidGlassQaMode.chromaticOnly:
        return 'Chromatic Only';
      case LiquidGlassQaMode.fresnelOnly:
        return 'Fresnel Only';
      case LiquidGlassQaMode.shapeOnly:
        return 'Shape Only';
    }
  }

  String _patternLabel(LiquidGlassQaPattern pattern) {
    switch (pattern) {
      case LiquidGlassQaPattern.horizontal:
        return 'Horizontal';
      case LiquidGlassQaPattern.vertical:
        return 'Vertical';
      case LiquidGlassQaPattern.checker:
        return 'Checker';
      case LiquidGlassQaPattern.text:
        return 'Text';
    }
  }

  String _colorPresetLabel(LiquidNavColorPreset preset) {
    switch (preset) {
      case LiquidNavColorPreset.sylulive:
        return 'SYLUlive';
      case LiquidNavColorPreset.coolapkReference:
        return 'Coolapk reference';
    }
  }
}

class _LiquidGlassQaPatternPainter extends CustomPainter {
  const _LiquidGlassQaPatternPainter(this.pattern);

  final LiquidGlassQaPattern pattern;

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
      ..color = Colors.white.withValues(alpha: 0.25);
    switch (pattern) {
      case LiquidGlassQaPattern.horizontal:
        for (var y = 40.0; y < size.height; y += 34) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
        }
      case LiquidGlassQaPattern.vertical:
        for (var x = 16.0; x < size.width; x += 28) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
        }
      case LiquidGlassQaPattern.checker:
        for (var x = -size.height; x < size.width + size.height; x += 22) {
          canvas.drawLine(
            Offset(x, 0),
            Offset(x + size.height, size.height),
            grid,
          );
        }
        for (var y = 18.0; y < size.height; y += 36) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
        }
      case LiquidGlassQaPattern.text:
        _paintText(canvas, size);
    }

    final blobs = Paint()..color = const Color(0x66FFFFFF);
    canvas.drawCircle(Offset(size.width * 0.18, size.height * 0.28), 76, blobs);
    canvas.drawCircle(
        Offset(size.width * 0.80, size.height * 0.46), 112, blobs);
    canvas.drawCircle(Offset(size.width * 0.48, size.height * 0.78), 58, blobs);
  }

  @override
  bool shouldRepaint(covariant _LiquidGlassQaPatternPainter oldDelegate) =>
      oldDelegate.pattern != pattern;

  void _paintText(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: const TextSpan(
        text: '沈理校园  SYLUlive\nABCDE  123456789',
        style: TextStyle(
          color: Colors.white,
          fontSize: 26,
          height: 1.55,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 32);
    painter.paint(canvas, const Offset(16, 180));
  }
}
