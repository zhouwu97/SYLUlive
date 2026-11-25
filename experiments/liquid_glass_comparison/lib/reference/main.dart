import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'widgets/bottom_nav.dart';
import 'widgets/liquid_glass/liquid_glass_runtime.dart';
import 'widgets/liquid_glass/liquid_glass_scene.dart';

void main() => runApp(const NavigationDemo());

class NavigationDemo extends StatefulWidget {
  const NavigationDemo({super.key});
  @override
  State<NavigationDemo> createState() => _NavigationDemoState();
}

class _NavigationDemoState extends State<NavigationDemo> {
  int index = 0;
  BottomNavStyle style = BottomNavStyle.liquidGlass;
  bool dark = false;
  bool grid = false;
  bool compare = false;
  bool clear = false;
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Liquid / 液态玻璃',
      theme: ThemeData(
        fontFamily: 'NotoSansCJKsc',
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2369c8),
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
      ),
      home: Scaffold(
        body: LiquidGlassScene(
          background: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _Wallpaper(dark: dark, grid: grid),
              ),
              SafeArea(
                bottom: false,
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 680),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: const BoxDecoration(
                                        color: Color(0xff287be9),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 9),
                                    const Text(
                                      'LIQUID / 01',
                                      style: TextStyle(
                                        fontSize: 12,
                                        letterSpacing: 2,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      tooltip: dark ? '切换浅色模式' : '切换深色模式',
                                      onPressed: () =>
                                          setState(() => dark = !dark),
                                      icon: Icon(
                                        dark
                                            ? Icons.light_mode_outlined
                                            : Icons.dark_mode_outlined,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                const Text(
                                  '触得到的光。',
                                  style: TextStyle(
                                    fontSize: 35,
                                    height: 1.3,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -1.5,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '慢拖、快甩，再突然反向。\n让玻璃跟着你的力度变形。',
                                  style: TextStyle(
                                    fontSize: 14,
                                    height: 1.8,
                                    color: dark
                                        ? Colors.white70
                                        : const Color(0xff53627a),
                                  ),
                                ),
                                const SizedBox(height: 28),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final entry in const {
                                      BottomNavStyle.liquidGlass: '液态玻璃',
                                      BottomNavStyle.floating: '悬浮底栏',
                                      BottomNavStyle.normal: '普通底栏',
                                    }.entries)
                                      ChoiceChip(
                                        label: Text(entry.value),
                                        selected: style == entry.key,
                                        onSelected: (_) =>
                                            setState(() => style = entry.key),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 24),
                                Container(
                                  padding: const EdgeInsets.all(22),
                                  decoration: BoxDecoration(
                                    color:
                                        (dark
                                                ? const Color(0xff142033)
                                                : Colors.white)
                                            .withValues(alpha: .62),
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: dark ? .12 : .65,
                                      ),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            BottomNav.icons[index],
                                            size: 25,
                                            color: dark
                                                ? const Color(0xff84baff)
                                                : const Color(0xff1765da),
                                          ),
                                          const SizedBox(width: 12),
                                          Text(
                                            BottomNav.labels[index],
                                            key: const ValueKey(
                                              'current-page-title',
                                            ),
                                            style: const TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const Spacer(),
                                          const Text(
                                            'PREVIEW',
                                            style: TextStyle(
                                              fontSize: 9,
                                              letterSpacing: 2,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 18),
                                      const Text(
                                        '一块玻璃，两层透镜',
                                        style: TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        '慢拖时轻柔弯曲，快甩时拉长压扁。突然停住或反向拖动，玻璃带着惯性回弹，折射与高光跟随轮廓一起变化。',
                                        style: TextStyle(
                                          fontSize: 13,
                                          height: 1.8,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    FilterChip(
                                      label: const Text('网格背景'),
                                      selected: grid,
                                      onSelected: (v) =>
                                          setState(() => grid = v),
                                    ),
                                    FilterChip(
                                      label: const Text('清透材质'),
                                      selected: clear,
                                      onSelected: (v) =>
                                          setState(() => clear = v),
                                    ),
                                    FilterChip(
                                      label: const Text('仅模糊对照'),
                                      selected: compare,
                                      onSelected: (v) =>
                                          setState(() => compare = v),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                ValueListenableBuilder(
                                  valueListenable: liquidGlassRuntimeStatus,
                                  builder: (context, status, _) => Text(
                                    status.tier == LiquidGlassTier.a
                                        ? '● 实时折射 · Flutter GPU'
                                        : status.tier == LiquidGlassTier.c
                                        ? '○ 基础渲染 · ${status.detail}'
                                        : '○ 正在准备玻璃',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: dark
                                          ? Colors.white60
                                          : const Color(0xff53627a),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 28),
                                const Text(
                                  '向上滚动，让内容经过底栏',
                                  style: TextStyle(
                                    fontSize: 12,
                                    letterSpacing: .5,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                for (var i = 0; i < 6; i++)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 16),
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(20),
                                      color:
                                          (dark
                                                  ? const Color(0xff173045)
                                                  : Colors.white)
                                              .withValues(alpha: .68),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 48,
                                          height: 48,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: [
                                              const Color(0xff87b5e8),
                                              const Color(0xffe5a9a9),
                                              const Color(0xff81c6b5),
                                            ][i % 3],
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                          child: Text(
                                            '0${i + 1}',
                                            style: const TextStyle(
                                              fontSize: 20,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                ['光的边界', '连续的形变', '玻璃里的内容'][i %
                                                    3],
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(height: 5),
                                              const Text(
                                                '滚动观察文字、线条与颜色的折射',
                                                style: TextStyle(fontSize: 11),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                const SizedBox(height: 130),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          overlay: Align(
            alignment: Alignment.bottomCenter,
            child: BottomNav(
              currentIndex: index,
              style: style,
              onTap: (value) => setState(() => index = value),
              compareGlass: compare,
              glassBlur: clear ? 0 : 6,
              glassTint: clear ? .06 : null,
              badges: const {1: true},
            ),
          ),
        ),
      ),
    );
  }
}

class _Wallpaper extends CustomPainter {
  const _Wallpaper({required this.dark, required this.grid});
  final bool dark;
  final bool grid;
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
              ? const [Color(0xff111f32), Color(0xff18374c), Color(0xff3e3449)]
              : const [Color(0xffe5edf5), Color(0xffd5e8ee), Color(0xffe8cdd4)],
        ).createShader(rect),
    );
    if (grid) {
      final paint = Paint()
        ..color = (dark ? Colors.white : const Color(0xff386a91)).withValues(
          alpha: .35,
        )
        ..strokeWidth = 1;
      for (double x = 0; x <= size.width; x += 22) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
      for (double y = 0; y <= size.height; y += 22) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
      return;
    }
    for (var i = 0; i < 7; i++) {
      final y = size.height * .62 + i * 62;
      final path = Path()
        ..moveTo(-80, y + 140)
        ..cubicTo(
          size.width * .26,
          y - 100,
          size.width * .55,
          y + 140,
          size.width + 80,
          y - 100,
        )
        ..lineTo(size.width + 80, size.height + 400)
        ..lineTo(-80, size.height + 400)
        ..close();
      canvas.drawShadow(path, Colors.black.withValues(alpha: .16), 15, false);
      final palette = dark
          ? const [
              Color(0xff294e73),
              Color(0xff24627a),
              Color(0xff55537d),
              Color(0xff655164),
            ]
          : const [
              Color(0xff95b8e6),
              Color(0xffa4d8dd),
              Color(0xffc2bbdf),
              Color(0xffecc8c5),
            ];
      canvas.drawPath(
        path,
        Paint()
          ..shader =
              LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [palette[i % 4], palette[(i + 1) % 4]],
              ).createShader(
                Rect.fromLTWH(
                  0,
                  y - 100,
                  size.width,
                  math.max(220, size.height - y),
                ),
              ),
      );
    }
  }

  @override
  bool shouldRepaint(_Wallpaper oldDelegate) =>
      dark != oldDelegate.dark || grid != oldDelegate.grid;
}
