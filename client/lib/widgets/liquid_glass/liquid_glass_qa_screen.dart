import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../liquid_bottom_nav.dart';
import 'liquid_glass_runtime.dart';

class LiquidGlassReferenceParityScreen extends StatelessWidget {
  const LiquidGlassReferenceParityScreen({super.key});
  @override
  Widget build(BuildContext context) => const LiquidGlassQaScreen();
}

/// 使用正式组件与真实背景采样，避免参数面板验证另一套旧渲染器。
class LiquidGlassQaScreen extends StatefulWidget {
  const LiquidGlassQaScreen({super.key});
  @override
  State<LiquidGlassQaScreen> createState() => _LiquidGlassQaScreenState();
}

class _LiquidGlassQaScreenState extends State<LiquidGlassQaScreen> {
  final _position = ValueNotifier(2.0);
  int _selected = 2;
  bool _compare = false, _clear = false;
  double _intensity = 1;
  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode) {
      return const Scaffold(
          body: Center(child: Text('Liquid Glass QA 仅在开发包可用')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Liquid Glass Reference QA')),
      body: LiquidGlassScene(
        background: Stack(fit: StackFit.expand, children: [
          CustomPaint(
              painter: _GridPainter(
                  Theme.of(context).brightness == Brightness.dark)),
          ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 128),
              children: [
                const Text('慢拖、快甩、突然反向',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                const Text('同一距离用不同速度拖动；按住不动会恢复，松手后保留惯性。背景、图标和高光一起经过变形透镜。'),
                SwitchListTile(
                    title: const Text('仅模糊对照'),
                    value: _compare,
                    onChanged: (v) => setState(() => _compare = v)),
                SwitchListTile(
                    title: const Text('清透材质'),
                    value: _clear,
                    onChanged: (v) => setState(() => _clear = v)),
                const Text('局部测试强度（不修改用户设置）'),
                Slider(
                    value: _intensity,
                    onChanged: (v) => setState(() => _intensity = v)),
                ValueListenableBuilder<LiquidGlassRuntimeStatus>(
                    valueListenable: liquidGlassRuntimeStatus,
                    builder: (context, status, child) =>
                        Text('Tier ${status.tierLabel} · ${status.detail}')),
                const SizedBox(height: 400),
                const Text('滚动文字与网格穿过玻璃', style: TextStyle(fontSize: 28)),
                const SizedBox(height: 160),
              ]),
        ]),
        overlay: Align(
            alignment: Alignment.bottomCenter,
            child: LiquidBottomNav(
              currentIndex: _selected,
              visualIndexListenable: _position,
              onTap: (v) => setState(() => _selected = v),
              compare: _compare,
              intensity: _intensity,
              blur: _clear ? 0 : 6,
              tint: _clear ? .06 : null,
            )),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.dark);
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(dark ? const Color(0xff233344) : const Color(0xffdaebef),
        BlendMode.src);
    final pen = Paint()
      ..color = dark ? Colors.white24 : Colors.blueGrey.withValues(alpha: .4)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 22) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), pen);
    }
    for (double y = 0; y < size.height; y += 22) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), pen);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.dark != dark;
}
