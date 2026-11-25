import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../utils/responsive_util.dart';
import '../liquid_bottom_nav.dart';
import 'liquid_glass_runtime.dart';
import 'liquid_glass_switch.dart';

class LiquidGlassReferenceParityScreen extends StatelessWidget {
  const LiquidGlassReferenceParityScreen({super.key});
  @override
  Widget build(BuildContext context) => LiquidGlassQaScreen(
      axis: ResponsiveUtil.useSideNavigation(context)
          ? Axis.vertical
          : Axis.horizontal);
}

/// 使用正式组件与真实背景采样，避免参数面板验证另一套旧渲染器。
class LiquidGlassQaScreen extends StatefulWidget {
  const LiquidGlassQaScreen({super.key, this.axis = Axis.horizontal});
  final Axis axis;
  @override
  State<LiquidGlassQaScreen> createState() => _LiquidGlassQaScreenState();
}

class _LiquidGlassQaScreenState extends State<LiquidGlassQaScreen> {
  final _position = ValueNotifier(2.0);
  final _switchScene = LiquidGlassSceneSource();
  final _scroll = ScrollController();
  int _selected = 2;
  bool _compare = false, _clear = false;
  bool _switchOn = true, _switchReady = false, _reduceSwitch = false;
  double _intensity = 1;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_switchScene.frameChanged);
  }

  @override
  void dispose() {
    _position.dispose();
    _scroll.dispose();
    _switchScene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vertical = widget.axis == Axis.vertical;
    if (kReleaseMode) {
      return const Scaffold(
          body: Center(child: Text('Liquid Glass QA 仅在开发包可用')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Liquid Glass Reference QA')),
      body: LiquidGlassScene(
        background: Stack(fit: StackFit.expand, children: [
          LiquidGlassBackground(
            source: _switchScene,
            child: CustomPaint(
                painter: _GridPainter(
                    Theme.of(context).brightness == Brightness.dark)),
          ),
          ListView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                  vertical ? 136 : 24, 24, 24, vertical ? 24 : 128),
              children: [
                const Text('慢拖、快甩、突然反向',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                const Text(
                    '底座始终保留清透折射和亮边；按住按钮才出现透镜。拖动速度决定拉伸和弯曲，松手后胶囊随回弹退场，底座保持原样。'),
                SwitchListTile(
                    title: const Text('仅模糊对照'),
                    value: _compare,
                    onChanged: (v) => setState(() => _compare = v)),
                SwitchListTile(
                    title: const Text('清透材质'),
                    value: _clear,
                    onChanged: (v) => setState(() => _clear = v)),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                      child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('液态玻璃开关 · 正式组件',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      Text(
                          '${_switchOn ? '已开启' : '已关闭'} · ${_switchReady ? 'GPU 透镜已就绪' : '普通开关'}'),
                    ],
                  )),
                  MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                        disableAnimations:
                            MediaQuery.disableAnimationsOf(context) ||
                                _reduceSwitch),
                    child: LiquidGlassSwitch(
                      key: const ValueKey('qa-liquid-switch'),
                      label: '液态玻璃开关试用',
                      value: _switchOn,
                      onChanged: (value) => setState(() => _switchOn = value),
                      source: _switchScene,
                      compare: _compare,
                      intensity: _intensity,
                      onOpticsReadyChanged: (ready) =>
                          setState(() => _switchReady = ready),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                const Text('轻点从原端鼓起、滑向另一端再收回；按住可手动拖动和反向回弹。本样例不保存设置。'),
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('减少开关动画'),
                    value: _reduceSwitch,
                    onChanged: (value) =>
                        setState(() => _reduceSwitch = value!)),
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
            alignment: vertical ? Alignment.centerLeft : Alignment.bottomCenter,
            child: LiquidBottomNav(
              axis: widget.axis,
              currentIndex: _selected,
              visualIndexListenable: _position,
              onTap: (v) => setState(() => _selected = v),
              compare: _compare,
              intensity: _intensity,
              blur: _clear ? 0 : 2,
              tint: _clear ? .06 : .26,
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
