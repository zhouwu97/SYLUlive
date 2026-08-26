import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../bottom_nav.dart';
import 'liquid_glass_runtime.dart';

enum LiquidGlassQaPattern { optical, horizontal, vertical, checker, text }

/// Gate 1–8 的固定对照入口。它复用同一套 QA 状态机，但把参考基线、
/// SYLUlive 当前参数和 optical debug 放在同一屏，避免直接拿业务 Feed 猜材质。
class LiquidGlassReferenceParityScreen extends StatelessWidget {
  const LiquidGlassReferenceParityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const LiquidGlassQaScreen(referenceParity: true);
  }
}

/// 仅 Debug/Profile 开发包使用的 Liquid Glass 视觉 QA 页面。
///
/// 页面不改变业务导航，只把纹理背景和光学参数暴露出来，便于在真实
/// 模拟器/设备上先记录 Tier，再比较轮廓、折射和 Dock haze。
class LiquidGlassQaScreen extends StatefulWidget {
  const LiquidGlassQaScreen({super.key, this.referenceParity = false});

  final bool referenceParity;

  @override
  State<LiquidGlassQaScreen> createState() => _LiquidGlassQaScreenState();
}

class _LiquidGlassQaScreenState extends State<LiquidGlassQaScreen> {
  late final ValueNotifier<double> _visualPosition;
  var _currentIndex = 2;
  var _tuning = const LiquidGlassTuning();
  var _pattern = LiquidGlassQaPattern.optical;
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
        body: Center(child: Text('液态玻璃 QA 仅在开发包可用')),
      );
    }

    final authProvider = context.read<AuthProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.referenceParity ? '液态玻璃参考对照' : '液态玻璃 QA',
        ),
      ),
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.referenceParity)
            const ColoredBox(
              key: ValueKey('liquid-glass-reference-background'),
              color: Colors.white,
            )
          else
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
        showDiagnostics: true,
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
            if (widget.referenceParity) _buildReferenceContract(),
            const Text(
              '常态保留模糊与基础透镜；长按或切换标签页时再观察折射、色散与边缘连接。红框是采样范围，青框是胶囊可见曲面。',
              style: TextStyle(color: Colors.white),
            ),
            if (widget.referenceParity) ...[
              const SizedBox(height: 6),
              const Text(
                '颜色合成：普通导航行全部保持中性；品牌色只来自胶囊内的强调副本，窗口外不应出现色调。',
                style: TextStyle(color: Colors.white),
              ),
            ],
            const SizedBox(height: 8),
            const Text('预设', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildQaChip(
                  '当前 · HEAD',
                  _isPreset(LiquidGlassTuning.current),
                  () => _setPreset(LiquidGlassTuning.current),
                ),
                _buildQaChip(
                  '旧版 v1 · 57ca812',
                  _isPreset(LiquidGlassTuning.oldV1),
                  () => _setPreset(LiquidGlassTuning.oldV1),
                ),
                _buildQaChip(
                  '自然',
                  _isPreset(LiquidGlassTuning.natural),
                  () => _setPreset(LiquidGlassTuning.natural),
                ),
                _buildQaChip(
                  '酷安参考',
                  _isPreset(LiquidGlassTuning.coolapk),
                  () => _setPreset(LiquidGlassTuning.coolapk),
                ),
                _buildQaChip(
                  '增强',
                  _isPreset(LiquidGlassTuning.strong),
                  () => _setPreset(LiquidGlassTuning.strong),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'A/B：当前使用 MCP HEAD；旧版 v1 复现 57ca812（2026-08-24 09:13），只切换视觉档案，不切换导航状态机。',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 6),
            const Text(
              'C. 光学调试 / 模式',
              style: TextStyle(color: Colors.white70),
            ),
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
            const Text('颜色预设', style: TextStyle(color: Colors.white70)),
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
              '交互状态',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildQaChip(
                  '静止',
                  _qaPhase == LiquidNavPhase.idle,
                  () => _setQaPhase(LiquidNavPhase.idle, 0),
                ),
                _buildQaChip(
                  '按压 25%',
                  _qaPhase == LiquidNavPhase.pressing && _qaActivation == 0.25,
                  () => _setQaPhase(LiquidNavPhase.pressing, 0.25),
                ),
                _buildQaChip(
                  '按压 50%',
                  _qaPhase == LiquidNavPhase.pressing && _qaActivation == 0.50,
                  () => _setQaPhase(LiquidNavPhase.pressing, 0.50),
                ),
                _buildQaChip(
                  '按压 100%',
                  _qaPhase == LiquidNavPhase.pressing && _qaActivation == 1,
                  () => _setQaPhase(LiquidNavPhase.pressing, 1),
                ),
                _buildQaChip(
                  '拖拽中',
                  _qaPhase == LiquidNavPhase.dragging,
                  () => _setQaPhase(LiquidNavPhase.dragging, 1),
                ),
                _buildQaChip(
                  '吸附中',
                  _qaPhase == LiquidNavPhase.settling,
                  () => _setQaPhase(LiquidNavPhase.settling, 1),
                ),
                _buildQaChip(
                  '收拢中',
                  _qaPhase == LiquidNavPhase.collapsing,
                  () => _setQaPhase(LiquidNavPhase.collapsing, 0.55),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text('背景图案', style: TextStyle(color: Colors.white70)),
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
                '显示采样范围',
                style: TextStyle(color: Colors.white),
              ),
              value: _tuning.showCaptureBounds,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(showCaptureBounds: value),
              ),
            ),
            const SizedBox(height: 6),
            _buildSlider(
              label: '折射力度',
              value: _tuning.refraction,
              min: 0,
              max: 28,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(refraction: value),
              ),
            ),
            _buildSlider(
              label: '折射深度',
              value: _tuning.refractionHeight,
              min: 0,
              max: 24,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(refractionHeight: value),
              ),
            ),
            _buildSlider(
              label: '按压缩放',
              value: _tuning.pressedScale,
              min: 1,
              max: 1.45,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(pressedScale: value),
              ),
            ),
            _buildSlider(
              label: '纵向折射比例',
              value: _tuning.verticalRefractionScale,
              min: 0.08,
              max: 0.70,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(verticalRefractionScale: value),
              ),
            ),
            _buildSlider(
              label: '横向采样余量',
              value: _tuning.overscanX,
              min: 12,
              max: 40,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(overscanX: value),
              ),
            ),
            _buildSlider(
              label: '纵向采样余量',
              value: _tuning.overscanY,
              min: 8,
              max: 32,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(overscanY: value),
              ),
            ),
            _buildSlider(
              label: '色散',
              value: _tuning.chromatic,
              min: 0,
              max: 3,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(chromatic: value),
              ),
            ),
            _buildSlider(
              label: '旧版边缘参数',
              value: _tuning.rimStrength,
              min: 0,
              max: 2,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(rimStrength: value),
              ),
            ),
            _buildSlider(
              label: '旧版光照参数',
              value: _tuning.lightStrength,
              min: 0,
              max: 0.8,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(lightStrength: value),
              ),
            ),
            _buildSlider(
              label: '底栏透明度',
              value: _tuning.dockAlpha,
              min: 0,
              max: 1,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(dockAlpha: value),
              ),
            ),
            _buildSlider(
              label: '底栏模糊',
              value: _tuning.dockBlur,
              min: 0,
              max: 14,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(dockBlur: value),
              ),
            ),
            _buildSlider(
              label: '选中态静止折射（QA）',
              value: _tuning.idleOpticalActivation,
              min: 0,
              max: 0.6,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(idleOpticalActivation: value),
              ),
            ),
            _buildSlider(
              label: '底栏折射力度',
              value: _tuning.dockRefraction,
              min: 0,
              max: 40,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(dockRefraction: value),
              ),
            ),
            _buildSlider(
              label: '底栏色散',
              value: _tuning.dockChromatic,
              min: 0,
              max: 0.5,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(dockChromatic: value),
              ),
            ),
            _buildSlider(
              label: '高光强度',
              value: _tuning.highlightStrength,
              min: 0,
              max: 1.5,
              onChanged: (value) => _setTuning(
                _tuning.copyWith(highlightStrength: value),
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

  Widget _buildReferenceContract() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'A. Kyant 参数（冻结基线）',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          const Text(
            '底栏 64 / 模糊 8 / 常驻透镜 24×24\n'
            '选中态 56 / 静止透镜 16×22 / 按压、拖拽透镜 16×22\n'
            '标签页内容 1.20× / 指针高光 0.08+0.15 / 底栏回弹 3.5dp',
            style: TextStyle(color: Colors.white70, height: 1.35),
          ),
          const SizedBox(height: 6),
          const Text(
            'B. SYLUlive 参数',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          Text(
            '强调色 ${_tuning.focusColorFor(false).toARGB32().toRadixString(16)} · '
            '选中态 ${_tuning.refractionHeight.toStringAsFixed(0)}×'
            '${_tuning.refraction.toStringAsFixed(0)} · '
            '底栏模糊 ${_tuning.dockBlur.toStringAsFixed(0)} / '
            '底栏透镜 ${_tuning.dockRefractionHeight.toStringAsFixed(0)}×'
            '${_tuning.dockRefraction.toStringAsFixed(0)} / '
            '生产态保留曲面高光，不叠加 Halo/Rim',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 8),
        ],
      ),
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
    return _tuning.visualProfile == preset.visualProfile &&
        _tuning.pressedScale == preset.pressedScale &&
        _tuning.refractionHeight == preset.refractionHeight &&
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
        return '最终玻璃';
      case LiquidGlassQaMode.identity:
        return '原样';
      case LiquidGlassQaMode.coreOnly:
        return '仅模糊';
      case LiquidGlassQaMode.refractionOnly:
        return '仅折射';
      case LiquidGlassQaMode.chromaticOnly:
        return '仅色散';
      case LiquidGlassQaMode.fresnelOnly:
        return '仅高光';
      case LiquidGlassQaMode.shapeOnly:
        return '仅形状';
    }
  }

  String _patternLabel(LiquidGlassQaPattern pattern) {
    switch (pattern) {
      case LiquidGlassQaPattern.optical:
        return '光学测试';
      case LiquidGlassQaPattern.horizontal:
        return '横向';
      case LiquidGlassQaPattern.vertical:
        return '纵向';
      case LiquidGlassQaPattern.checker:
        return '棋盘';
      case LiquidGlassQaPattern.text:
        return '文字';
    }
  }

  String _colorPresetLabel(LiquidNavColorPreset preset) {
    switch (preset) {
      case LiquidNavColorPreset.sylulive:
        return 'SYLUlive';
      case LiquidNavColorPreset.coolapkReference:
        return '酷安参考';
    }
  }
}

class _LiquidGlassQaPatternPainter extends CustomPainter {
  const _LiquidGlassQaPatternPainter(this.pattern);

  final LiquidGlassQaPattern pattern;

  @override
  void paint(Canvas canvas, Size size) {
    if (pattern == LiquidGlassQaPattern.optical) {
      _paintOpticalBackdrop(canvas, size);
      return;
    }

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
      case LiquidGlassQaPattern.optical:
        break;
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

  void _paintOpticalBackdrop(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFF7FAF8),
    );

    // 高对比色块把“背景采样坐标被移动”放大出来，避免在白色 Feed 上
    // 把真实折射误判成普通 BackdropFilter。
    final blocks = <({Rect rect, Color color})>[
      (
        rect: Rect.fromLTWH(-18, 76, size.width * 0.42, size.height * 0.26),
        color: const Color(0xFFF28C28),
      ),
      (
        rect: Rect.fromLTWH(
          size.width * 0.23,
          118,
          size.width * 0.52,
          size.height * 0.28,
        ),
        color: const Color(0xFF21A366),
      ),
      (
        rect: Rect.fromLTWH(
          size.width * 0.68,
          66,
          size.width * 0.40,
          size.height * 0.38,
        ),
        color: const Color(0xFF1976D2),
      ),
      (
        rect: Rect.fromLTWH(
          size.width * 0.04,
          size.height * 0.45,
          size.width * 0.31,
          size.height * 0.22,
        ),
        color: const Color(0xFFE54848),
      ),
    ];
    for (final block in blocks) {
      canvas.drawRect(block.rect, Paint()..color = block.color);
    }

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.black.withValues(alpha: 0.72);
    for (var y = size.height * 0.24; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var x = 12.0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    const checkerSize = 18.0;
    final checkerOrigin = Offset(12, size.height * 0.58);
    for (var row = 0; row < 4; row++) {
      for (var column = 0; column < 9; column++) {
        final isBlack = (row + column).isEven;
        final rect = Rect.fromLTWH(
          checkerOrigin.dx + column * checkerSize,
          checkerOrigin.dy + row * checkerSize,
          checkerSize,
          checkerSize,
        );
        canvas.drawRect(
          rect,
          Paint()..color = isBlack ? Colors.black : Colors.white,
        );
      }
    }

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black.withValues(alpha: 0.82);
    canvas.drawCircle(
        Offset(size.width * 0.17, size.height * 0.76), 42, outline);
    canvas.drawCircle(
        Offset(size.width * 0.78, size.height * 0.72), 58, outline);

    final painter = TextPainter(
      text: const TextSpan(
        text: 'SYLUlive  LIQUID LENS\n橙 绿 蓝 · 1px grid · 123456789',
        style: TextStyle(
          color: Colors.black,
          fontSize: 20,
          height: 1.45,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 32);
    painter.paint(canvas, Offset(16, size.height * 0.30));
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
