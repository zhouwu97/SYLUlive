# 本次验证记录

日期：2026-11-24。范围：独立 Flutter Web 实验，R1。Flutter 3.41.8 / Dart 3.11.5，Windows；浏览器为 Codex 内置 Chromium / CanvasKit。

## 已验证

- `flutter analyze`：最终无问题。
- `flutter test --no-pub --reporter expanded`：4 项通过，覆盖输入同步、35% 动效保留按压激活、取消、手动与系统减少动态、390 宽布局、原版完整路由、shader alpha 与中性背景透射。
- `flutter build web --release --no-web-resources-cdn`：成功，CanvasKit 与字体从本机加载。构建报告未包含的 Cupertino 字体；本实验使用 Material 图标，实际页面图标已检查。
- 原版 lib 与 shader 对照固定上游版本的 no-index diff：未修改。
- 浏览器真实鼠标：在左侧按住、移向右侧、反向、释放；两组同步。证据为 `build/verification/web-real-drag.jpg` 和 `web-real-reversal.jpg`。
- 深色、彩色背景、保持按压、光学／形变范围切换：页面与材质可用。
- 390 × 844 浏览器视口：两组上下排列，可滚动操作，没有横向布局溢出。已恢复正常浏览器尺寸。
- 原项目完整 demo：浏览器打开，原版页面、原版导航及返回可用，证据 `web-original-demo.jpg`。
- 仅模糊开关：浏览器状态变更，材质区域实际像素变化，证据 `web-comparison.jpg` 与 `web-blur-only.jpg`。
- 自动轨迹：开始后显示“停止演示”，九秒结束后恢复播放入口并释放；最终回到保持按压的展示状态。
- 加载失败与重试：仅阻断本机 refined_glass.frag 请求，页面显示错误与“重新加载”；解除阻断后点击重试，带新资源键加载并恢复两组材质。请求阻断及缓存覆盖均已清除。

## 首次失败与处理

1. 首次静态检查漏导入 kPrimaryButton，补充 Flutter gestures 导入。
2. 首次 Widget 检查发现 Semantics increase/decrease 有 value 但没有 increasedValue/decreasedValue，补齐可访问性状态；原用例通过。
3. 初始白底像素比较假定改进版比原版亮 8 个单位。实际两者在指定区域均为 255，白底高亮端没有分辨该差异。保留 `build/first-repair-tests.log` 与后续诊断日志，改用中灰背景检查透射偏差并保留透明边界检查；没有把白底结果写成暗圈改善证据。
4. 浏览器故障注入发现 CanvasKit 保留失败资源 Future，原重试按钮未恢复。手动重试改用新的查询键，重新执行阻断→错误→解除→点击→恢复链路，已通过。
5. 独立评审实际设置 Web `prefers-reduced-motion: reduce`，发现 Flutter 的 MediaQuery 未收到浏览器媒体偏好。加入原生 matchMedia change 监听，与 Flutter 无障碍和手动选项合并；开启时停止轨迹、清理按压和指针并恢复静态选择，dispose 移除监听。新增系统偏好活动中切换测试通过，真实 Web 已确认播放／按压入口禁用；独立复核见 INDEPENDENT_REVIEW.md。

截图来自实际浏览器，未使用生成式图片。`保持按压`、自动轨迹属于 demo 控制状态，与真实鼠标证据区分。

## 未覆盖

本轮没有集成到业务 App，没有测量手机性能、功耗和跨后端像素一致性。候选材质是否优于原版由对照页面观察决定；测试只证明列出的行为与像素属性。
