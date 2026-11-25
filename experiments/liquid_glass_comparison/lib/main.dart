import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'comparison_renderer.dart';
import 'browser_motion_stub.dart'
    if (dart.library.js_interop) 'browser_motion_web.dart';
import 'reference/main.dart' as reference;
import 'reference/widgets/liquid_glass/liquid_glass_dynamics.dart';
import 'reference/widgets/liquid_glass/liquid_glass_scene.dart';

void main() => runApp(const ComparisonApp());

class ComparisonApp extends StatefulWidget {
  const ComparisonApp({super.key});

  @override
  State<ComparisonApp> createState() => _ComparisonAppState();
}

class _ComparisonAppState extends State<ComparisonApp> {
  bool _dark = false;
  late final SemanticsHandle _semantics;
  final _browserMotion = BrowserMotion();

  @override
  void initState() {
    super.initState();
    _semantics = SemanticsBinding.instance.ensureSemantics();
    _browserMotion.addListener(_motionPreferenceChanged);
  }

  void _motionPreferenceChanged() => setState(() {});

  @override
  void dispose() {
    _semantics.dispose();
    _browserMotion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '液态玻璃 · 同步对照',
    debugShowCheckedModeBanner: false,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations:
            MediaQuery.disableAnimationsOf(context) || _browserMotion.value,
      ),
      child: child!,
    ),
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoSansCJKsc',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff2866cc),
        brightness: _dark ? Brightness.dark : Brightness.light,
      ),
      scaffoldBackgroundColor: _dark
          ? const Color(0xff14171e)
          : const Color(0xfff5f6f8),
    ),
    home: ComparisonPage(
      dark: _dark,
      onThemeChanged: () => setState(() => _dark = !_dark),
    ),
  );
}

enum SceneKind { grid, type, color }

class ComparisonPage extends StatefulWidget {
  const ComparisonPage({
    super.key,
    required this.dark,
    required this.onThemeChanged,
  });

  final bool dark;
  final VoidCallback onThemeChanged;

  @override
  State<ComparisonPage> createState() => _ComparisonPageState();
}

class _ComparisonPageState extends State<ComparisonPage>
    with TickerProviderStateMixin {
  late Future<List<ui.FragmentProgram>> _programs;
  int _loadAttempt = 0;
  late final LiquidGlassDynamics _motion;
  late final AnimationController _playback;
  SceneKind _scene = SceneKind.grid;
  bool _clear = true, _refineShape = false, _blurOnly = false;
  bool _held = false, _playing = false, _reduced = false;
  double _intensity = 1, _dockWidth = 440, _grabOffset = 0;
  int _selected = 2;
  int? _pointer;
  double _target = 2;
  Offset _light = const Offset(220, 0);

  @override
  void initState() {
    super.initState();
    _programs = _loadPrograms();
    _motion = LiquidGlassDynamics(vsync: this, index: 2);
    _playback =
        AnimationController(vsync: this, duration: const Duration(seconds: 9))
          ..addListener(_playFrame)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _motion.releaseTo(2);
              if (mounted) {
                setState(() {
                  _selected = 2;
                  _playing = false;
                });
              }
            }
          });
  }

  Future<List<ui.FragmentProgram>> _loadPrograms() => Future.wait([
    for (final asset in [
      'shaders/liquid_glass.frag',
      'shaders/refined_glass.frag',
    ])
      // CanvasKit retains failed asset futures. A manual retry needs a new key.
      ui.FragmentProgram.fromAsset(
        kIsWeb && _loadAttempt > 0 ? '$asset?retry=$_loadAttempt' : asset,
      ),
  ]);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = _reduced || MediaQuery.disableAnimationsOf(context);
    final changedToReduced = reduced && !_motion.reduced;
    _motion.reduced = reduced;
    if (changedToReduced) {
      _stopPlayback();
      _held = false;
      _pointer = null;
      _motion.snapTo(_selected.toDouble());
    }
  }

  @override
  void dispose() {
    _playback.dispose();
    _motion.dispose();
    super.dispose();
  }

  void _playFrame() {
    final t = _playback.value;
    if (t < .10) {
      _motion.releaseTo(0);
      return;
    }
    if (t > .84) {
      _motion.releaseTo(2);
      return;
    }
    final double at;
    if (t < .22) {
      at = 0;
    } else if (t < .56) {
      at = (t - .22) / .34 * 3.8;
    } else if (t < .66) {
      at = 3.8 - (t - .56) / .10 * 3.8;
    } else if (t < .77) {
      at = (t - .66) / .11 * 4;
    } else {
      at = 2;
    }
    _light = Offset(4 + (at + .5) * (_dockWidth - 8) / 5, 4);
    _motion.dragTo(at, pullY: math.sin(t * math.pi * 4) * 5);
  }

  void _stopPlayback() {
    _playback.stop();
    _playing = false;
  }

  void _togglePlayback() {
    setState(() {
      if (_playing) {
        _stopPlayback();
        _motion.releaseTo(_selected.toDouble());
      } else {
        _held = false;
        _pointer = null;
        _playing = true;
        _playback.forward(from: 0);
      }
    });
  }

  void _toggleHeld() {
    setState(() {
      _stopPlayback();
      _held = !_held;
      if (_held) {
        _light = Offset(4 + (_selected + .5) * (_dockWidth - 8) / 5, 0);
        _motion.grab();
        _motion.dragTo(_selected.toDouble());
      } else {
        _motion.releaseTo(_selected.toDouble());
      }
    });
  }

  void _down(PointerDownEvent event) {
    if (_pointer != null || event.buttons != kPrimaryButton) return;
    setState(_stopPlayback);
    _pointer = event.pointer;
    final item = (_dockWidth - 8) / 5;
    final at = (event.localPosition.dx - 4) / item - .5;
    _grabOffset = (at - _motion.position).abs() < .65
        ? at - _motion.position
        : 0;
    _target = (at - _grabOffset).clamp(0.0, 4.0);
    _light = event.localPosition;
    _motion.grab();
    _motion.dragTo(_target);
  }

  void _move(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    final item = (_dockWidth - 8) / 5;
    _target = ((event.localPosition.dx - 4) / item - .5 - _grabOffset).clamp(
      0.0,
      4.0,
    );
    _light = event.localPosition;
    _motion.dragTo(_target, pullY: (event.localPosition.dy - 32) * .25);
  }

  void _up(PointerUpEvent event) {
    if (_pointer != event.pointer) return;
    _pointer = null;
    _select(_target.round());
  }

  void _cancel([PointerCancelEvent? event]) {
    if (event != null && _pointer != event.pointer) return;
    _pointer = null;
    setState(() {
      _stopPlayback();
      _held = false;
    });
    _motion.releaseTo(_selected.toDouble());
  }

  void _select(int value) {
    setState(() => _selected = value.clamp(0, 4));
    if (_held) {
      _motion.dragTo(_selected.toDouble());
    } else {
      _motion.releaseTo(_selected.toDouble());
    }
  }

  LensPose get _pose => LensPose(
    position: _motion.position,
    press: _motion.pressure,
    stretch: _motion.stretch * _intensity,
    angle: _motion.angle,
    bend: _motion.bend * _intensity,
    vertical: _motion.vertical * _intensity,
    energy: _motion.energy * _intensity,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduced = _reduced || MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _select(_selected + 1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _select(_selected - 1),
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        },
        child: Focus(
          autofocus: true,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 30, 28, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.blur_on_rounded,
                          color: colors.primary,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'MATERIAL STUDY / 01',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 2,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: widget.onThemeChanged,
                          tooltip: widget.dark ? '切换浅色' : '切换深色',
                          icon: Icon(
                            widget.dark
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      '液态玻璃，同步对照。',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '在任意一侧按住导航并拖动，两侧同步。比较折射、边光与回弹。',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.8,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 24,
                      runSpacing: 16,
                      children: [
                        _control(
                          '背景',
                          SegmentedButton<SceneKind>(
                            segments: const [
                              ButtonSegment(
                                value: SceneKind.grid,
                                label: Text('网格'),
                              ),
                              ButtonSegment(
                                value: SceneKind.type,
                                label: Text('文字'),
                              ),
                              ButtonSegment(
                                value: SceneKind.color,
                                label: Text('彩色'),
                              ),
                            ],
                            selected: {_scene},
                            onSelectionChanged: (v) =>
                                setState(() => _scene = v.first),
                          ),
                        ),
                        _control(
                          '材质',
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: true, label: Text('清透')),
                              ButtonSegment(value: false, label: Text('原版磨砂')),
                            ],
                            selected: {_clear},
                            onSelectionChanged: (v) =>
                                setState(() => _clear = v.first),
                          ),
                        ),
                        _control(
                          '候选范围',
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, label: Text('只改光学')),
                              ButtonSegment(value: true, label: Text('光学＋形变')),
                            ],
                            selected: {_refineShape},
                            onSelectionChanged: (v) =>
                                setState(() => _refineShape = v.first),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: reduced ? null : _togglePlayback,
                          icon: Icon(
                            _playing
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                          ),
                          label: Text(_playing ? '停止演示' : '播放慢拖与快甩'),
                        ),
                        OutlinedButton.icon(
                          onPressed: reduced ? null : _toggleHeld,
                          icon: Icon(
                            _held
                                ? Icons.pan_tool_rounded
                                : Icons.touch_app_outlined,
                          ),
                          label: Text(_held ? '松开观察' : '保持按压'),
                        ),
                        FilterChip(
                          label: const Text('仅模糊对照'),
                          selected: _blurOnly,
                          onSelected: (v) => setState(() => _blurOnly = v),
                        ),
                        FilterChip(
                          label: const Text('减少动态'),
                          selected: _reduced,
                          onSelected: (v) {
                            _cancel();
                            setState(() => _reduced = v);
                            _motion.reduced =
                                v || MediaQuery.disableAnimationsOf(context);
                            _motion.snapTo(_selected.toDouble());
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      children: [
                        const Text('动效幅度', style: TextStyle(fontSize: 12)),
                        SizedBox(
                          width: 210,
                          child: Slider(
                            label: '${(_intensity * 100).round()}%',
                            value: _intensity,
                            onChanged: reduced
                                ? null
                                : (v) => setState(() => _intensity = v),
                          ),
                        ),
                        Text(
                          '${(_intensity * 100).round()}%',
                          style: const TextStyle(fontSize: 12),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _intensity = .35),
                          child: const Text('35%'),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _intensity = 1),
                          child: const Text('100%'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    FutureBuilder<List<ui.FragmentProgram>>(
                      future: _programs,
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              children: [
                                const Text('玻璃材质未能加载'),
                                const SizedBox(height: 8),
                                Text('${snapshot.error}'),
                                TextButton(
                                  onPressed: () => setState(() {
                                    _loadAttempt++;
                                    _programs = _loadPrograms();
                                  }),
                                  child: const Text('重新加载'),
                                ),
                              ],
                            ),
                          );
                        }
                        if (!snapshot.hasData) {
                          return const SizedBox(
                            height: 350,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 16),
                                  Text('正在准备两组玻璃材质…'),
                                ],
                              ),
                            ),
                          );
                        }
                        return LayoutBuilder(
                          builder: (context, constraints) {
                            final columns = constraints.maxWidth >= 720;
                            final width = columns
                                ? (constraints.maxWidth - 24) / 2
                                : constraints.maxWidth;
                            _dockWidth = math.min(440, width - 56);
                            _motion.configure((_dockWidth - 8) / 5);
                            return AnimatedBuilder(
                              animation: _motion,
                              builder: (context, _) {
                                final pose = _pose;
                                final panels = [
                                  _panel(width, false, snapshot.data![0], pose),
                                  _panel(width, true, snapshot.data![1], pose),
                                ];
                                return columns
                                    ? Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          panels[0],
                                          const SizedBox(width: 24),
                                          panels[1],
                                        ],
                                      )
                                    : Column(
                                        children: [
                                          panels[0],
                                          const SizedBox(height: 24),
                                          panels[1],
                                        ],
                                      );
                              },
                            );
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 22),
                    Text(
                      _refineShape
                          ? '右侧同时收敛沿轨道的膨胀；两侧仍使用相同的弹簧轨迹与按压值。'
                          : '只改光学：两侧的形状、位置、按压、模糊和染色参数完全相同。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.8,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            _cancel();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => Scaffold(
                                  appBar: AppBar(
                                    title: const Text('原项目完整 demo · a37134b'),
                                  ),
                                  body: const reference.NavigationDemo(),
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.open_in_new_rounded, size: 16),
                          label: const Text('打开原项目完整 demo'),
                        ),
                        Text(
                          'FlutterLiquidglass / a37134b · 独立实验，不修改业务 App',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _control(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 12)),
      const SizedBox(height: 8),
      child,
    ],
  );

  Widget _panel(
    double width,
    bool refined,
    ui.FragmentProgram program,
    LensPose pose,
  ) {
    final colors = Theme.of(context).colorScheme;
    final left = (width - _dockWidth) / 2;
    const top = 204.0;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: refined
                      ? const Color(0xff209278)
                      : colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                    refined ? '候选方案' : '原项目',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const Spacer(),
              Text(
                refined ? '边光 · 曲面 · 色散' : '原版 shader',
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              height: 320,
              child: LiquidGlassScene(
                background: RepaintBoundary(
                  child: CustomPaint(
                    painter: ScenePainter(dark: widget.dark, kind: _scene),
                  ),
                ),
                overlay: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: left - 48,
                      top: top - 48,
                      child: ComparisonRenderer(
                        key: ValueKey(
                          refined ? 'refined-renderer' : 'reference-renderer',
                        ),
                        program: program,
                        pose: pose,
                        dockWidth: _dockWidth,
                        pointer: _light,
                        refined: refined,
                        refineShape: _refineShape,
                        clear: _clear,
                        blurOnly: _blurOnly,
                      ),
                    ),
                    Positioned(
                      left: left,
                      top: top,
                      width: _dockWidth,
                      height: 64,
                      child: Semantics(
                        label: refined ? '改进导航' : '原版导航',
                        value: ComparisonRenderer.labels[_selected],
                        increasedValue: ComparisonRenderer
                            .labels[(_selected + 1).clamp(0, 4)],
                        decreasedValue: ComparisonRenderer
                            .labels[(_selected - 1).clamp(0, 4)],
                        onIncrease: () => _select(_selected + 1),
                        onDecrease: () => _select(_selected - 1),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Listener(
                            key: ValueKey(
                              refined ? 'refined-input' : 'reference-input',
                            ),
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: _down,
                            onPointerMove: _move,
                            onPointerUp: _up,
                            onPointerCancel: _cancel,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ScenePainter extends CustomPainter {
  const ScenePainter({required this.dark, required this.kind});

  final bool dark;
  final SceneKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xff172c42), Color(0xff453754)]
              : const [Color(0xffd6edf0), Color(0xffe9deef)],
        ).createShader(rect),
    );
    final line = Paint()
      ..strokeWidth = .8
      ..color = (dark ? Colors.white : const Color(0xff274b6c)).withValues(
        alpha: dark ? .22 : .25,
      );
    if (kind == SceneKind.color) {
      canvas.drawOval(
        Rect.fromLTWH(-60, 155, size.width * .96, 140),
        Paint()..color = const Color(0xff2d9abd).withValues(alpha: .72),
      );
      canvas.drawCircle(
        Offset(size.width * .76, 220),
        90,
        Paint()..color = const Color(0xffde6c9a).withValues(alpha: .68),
      );
      canvas.drawOval(
        Rect.fromLTWH(size.width * .44, 160, size.width * .55, 55),
        Paint()..color = const Color(0xffedc78a).withValues(alpha: .8),
      );
    }
    if (kind == SceneKind.grid || kind == SceneKind.color) {
      for (double x = 0; x < size.width; x += 22) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      }
      for (double y = 0; y < size.height; y += 22) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      }
    }
    final ink = dark ? const Color(0xffe0eaf5) : const Color(0xff284762);
    _text(canvas, 'REFRACTION / 折射', const Offset(24, 26), 15, ink);
    _text(
      canvas,
      '同一背景 · 同一输入',
      const Offset(24, 54),
      11,
      ink.withValues(alpha: .7),
    );
    if (kind == SceneKind.type) {
      for (var row = 0; row < 6; row++) {
        _text(
          canvas,
          row.isEven ? '0123456789  ABCDEFG  真实纹理' : '细线、文字与图标一起经过玻璃',
          Offset(20 + row % 2 * 16, 110 + row * 29),
          17,
          ink.withValues(alpha: row.isEven ? .85 : .55),
        );
      }
    } else {
      _text(canvas, '0123456789  ABCDEFG', const Offset(22, 192), 19, ink);
      _text(
        canvas,
        '光穿过曲面，边缘留下折射。',
        const Offset(22, 280),
        11,
        ink.withValues(alpha: .72),
      );
    }
  }

  void _text(Canvas canvas, String text, Offset at, double size, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'NotoSansCJKsc',
          fontSize: size,
          color: color,
          height: 1.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
    painter.dispose();
  }

  @override
  bool shouldRepaint(ScenePainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.kind != kind;
}
