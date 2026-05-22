import 'package:flutter/material.dart';

class CampusMapTabPage extends StatefulWidget {
  const CampusMapTabPage({Key? key}) : super(key: key);

  @override
  State<CampusMapTabPage> createState() => _CampusMapTabPageState();
}

class _CampusMapTabPageState extends State<CampusMapTabPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      // 💡 修复遮挡：Scaffold 的 body 内部用 SafeArea 包裹，确保绝不和底部导航栏重叠
      child: Column(
        children: [
          // 💡 修复滑动冲突 + 尺寸溢出：用 Expanded 顶住，让地图框自动缩放到最完美的剩余高度
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    )
                  ],
                ),
                clipBehavior: Clip.antiAlias, // 剪裁圆角
                child: Image.asset(
                  'assets/images/map.jpg', // 修正路径
                  fit: BoxFit.contain, // 确保整张大图能在框里完美完整显示
                ),
              ),
            ),
          ),

          // 💡 修复底部遮挡：按钮区域被牢牢框在底部，距离底部导航栏有安全的 16 像素留白
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 44, // 稍微加高一点，更好点按
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                  side: BorderSide(color: Colors.grey[300]!), // 极简白色边框
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 1,
                ),
                icon: const Icon(Icons.zoom_in, size: 18, color: Colors.black87),
                label: const Text(
                  '进入操控模式 (Only Scale)', 
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                onPressed: () {
                  // 点击瞬间唤起纯净置顶图层
                  _openMapControlMode(context);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 唤起全屏纯白按钮操控模式
  void _openMapControlMode(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (context, _, __) => const MapControlFullscreenOverlay(),
      ),
    );
  }
}

// ------------------- 完美的右侧纯白按钮全屏层 -------------------
class MapControlFullscreenOverlay extends StatefulWidget {
  const MapControlFullscreenOverlay({Key? key}) : super(key: key);

  @override
  State<MapControlFullscreenOverlay> createState() => _MapControlFullscreenOverlayState();
}

class _MapControlFullscreenOverlayState extends State<MapControlFullscreenOverlay> {
  final TransformationController _transformationController = TransformationController();

  void _zoomIn() {
    final Matrix4 matrix = _transformationController.value.clone();
    matrix.scale(1.3);
    _transformationController.value = matrix;
  }

  void _zoomOut() {
    final Matrix4 matrix = _transformationController.value.clone();
    matrix.scale(1 / 1.3);
    _transformationController.value = matrix;
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withOpacity(0.95), // 深色沉浸式背景
      body: SafeArea(
        child: Stack(
          children: [
            // 1. 独立手势层
            InteractiveViewer(
              transformationController: _transformationController,
              minScale: 1.0,
              maxScale: 6.0,
              panAxis: PanAxis.free,
              boundaryMargin: const EdgeInsets.all(200),
              child: Center(
                child: Image.asset(
                  'assets/images/map.jpg', // 修正路径
                  fit: BoxFit.contain,
                ),
              ),
            ),

            // 2. 底部左侧半透明说明小字 HUD
            Positioned(
              bottom: 24,
              left: 16,
              right: 88,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '当前：缩放操控模式',
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '仅可缩放，不可左右滑动切换版块。双指捏合或使用右侧按钮控制。',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),

            // 3. 右侧垂直排列的纯白按钮控制面板 (➕、➖、❌)
            Positioned(
              right: 16,
              bottom: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildWhiteButton(icon: Icons.add, label: '放大', onTap: _zoomIn),
                  const SizedBox(height: 12),
                  _buildWhiteButton(icon: Icons.remove, label: '缩小', onTap: _zoomOut),
                  const SizedBox(height: 12),
                  _buildWhiteButton(icon: Icons.close, label: '退出', onTap: () => Navigator.of(context).pop()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWhiteButton({required IconData icon, required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 62,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.96), // 优雅纯白
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 5, offset: Offset(0, 2))],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.black87, size: 20),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.black87, fontSize: 10, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
