# Flutter Web 液态玻璃同步对照

独立于业务 App 的实验。左右显示相同背景、尺寸、输入轨迹和材质参数，保留按压启用规则。默认只比较光学；“光学＋形变”才改变右侧沿轨道的膨胀。

参考：https://github.com/zhouwu97/FlutterLiquidglass

固定版本：`a37134be646771512854a5d4570bb819f125da58`。2026-11-24 通过 git ls-remote 核对为主分支 HEAD。

## 运行

Flutter 3.41.8 / Dart 3.11.5。在此目录执行：

```powershell
flutter pub get
flutter run -d chrome
```

构建本机预览：

```powershell
flutter build web --release --no-web-resources-cdn
python -m http.server 8787 --bind 127.0.0.1 --directory build/web
```

打开 http://127.0.0.1:8787/ 。构建资源本地加载，通过 HTTP 运行，不直接双击 index.html。

## 使用

- 任一侧按住导航拖动，两侧由同一个原版六弹簧状态驱动。松手选中并回弹；Esc 取消，方向键切换。
- “保持按压”便于静态观察；再次点击松开。
- “播放慢拖与快甩”播放九秒共同输入轨迹，最后释放。这是模型演示，与真实鼠标验收分开记录。
- 浏览器系统的“减少动态效果”、Flutter 无障碍状态和手动开关共同生效；活动中开启会停止轨迹并恢复静态选择，关闭后不重启旧动作。
- 网格、文字、彩色背景与深浅色用于检查折射、字形和彩边。
- 清透与原版磨砂均沿用上游 renderer 的按压模糊／染色公式。
- 动效幅度是宿主增加的共同控制，只改变两侧的拉伸、弯曲、偏移与运动能量，保留按压激活。上游完整 demo 没有该滑块。
- “仅模糊对照”传递各 shader 自己的 compare 开关；原版自身保留的基础压暗仍按原公式执行。
- “打开原项目完整 demo”直接运行随附原版 NavigationDemo，可返回。

## 基线与修改边界

lib/reference/、shaders/liquid_glass.frag 和字体保留上述固定版本的原文件。完整原版入口直接运行原组件。

同步页左侧使用原版 shader，comparison_renderer.dart 按上游 renderer 的图标图集、模糊、染色、uniform 和尺寸公式绘制。两侧使用同一试验宿主与采样区域；它不是原版完整页面的逐像素截图。采样与实际绘制均预留 48 DIP。

右侧 refined_glass.frag 改变：

1. 梯度长度用于局部一阶距离修正。
2. 曲面带同时用于折射坡度和边光。
3. 取消整圈内侧压暗，采用方向反射与环境色混合。
4. 保留七通道采样，色散限于 2 DIP 并按坡度渐隐。
5. 清透模式跳过零模糊离屏过程。
6. 可选：沿轨道按压膨胀从约 39% 降至 7.5%，横跨轨道幅度保留。

原许可在 licenses/。没有新增业务依赖；开发检查使用 Flutter SDK 测试与 flutter_lints。

字体与主仓库 `assets/fonts/NotoSansCJKsc-Regular.otf` 内容一致，供独立示例显示中文。Git 复用同一内容对象，没有新增另一份字体内容。

## 验证

```powershell
flutter analyze
flutter test --reporter expanded
```

测试覆盖同步、低强度保留激活、取消／减少动态、窄屏、原版路由，以及两组 shader 的透明边界和中性背景透射像素。浏览器截图放在忽略提交的 build/verification/。

本 demo 用于评估候选材质，不包含业务 App 集成，不声称跨后端像素一致。
