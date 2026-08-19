# SYLUlive Design QA 协议

- 状态：**冻结 v1**（2026-08-09）
- 定位：本文件只回答「**怎么证明这次 UI 修改真的合格**」。怎么设计见 `DESIGN_SYSTEM.md`，怎么动效见 `MOTION.md`。
- 适用范围：`client/` 所有 UI 相关改动（新页面、重构、迁移、Bug 修复涉及视觉时）。

## 1. QA 层级

三层测试职责分离，不得互相替代：

| 层 | 负责 |
| --- | --- |
| Provider / Unit Test | 业务状态、数据变换、缓存、请求规则 |
| Widget / Interaction Test | 控件存在、点击、输入、状态切换、导航、错误恢复 |
| Golden / Visual Test | 布局、间距、圆角、surface、换行、overflow、视觉层级 |

> Golden 不能代替 Widget test，Widget test 也不能证明视觉一致。

## 2. Severity 定义

| 级别 | 定义 |
| --- | --- |
| P0 | 无法完成核心操作、严重遮挡、导航失效、输入不可用 |
| P1 | 重要交互错误、状态无法恢复、明显布局破坏 |
| P2 | 明显视觉/一致性问题，但功能可用 |
| P3 | 轻微 polish |

### Gate

```text
普通 UI PR：
P0 = 0
P1 = 0

正式 redesign：
P0 = 0
P1 = 0
P2 = 0 或逐项解释
```

## 3. Canonical viewport

冻结的 Golden 基线矩阵：

| Profile | logical size | Theme | Text scale |
| --- | ---: | --- | --- |
| primary | 360×800 | light | 1.0 |
| wide-phone | 390×844 | light | 1.0 |
| dark | 360×800 | dark | 1.0 |
| large-text | 360×800 | light | 1.3 |

- `1.5` text scale 仅作为**高风险页面的 overflow stress test**，不是所有页面都要生成 Golden。
- viewport 与 text profile 通过 `client/test/helpers/` 统一设置，测试内禁止散落 `setSurfaceSize`。

## 4. Golden 平台

```text
Canonical baseline platform:
Ubuntu
Flutter 3.41.8 stable
```

与主 CI（`.github/workflows/ci.yml`）环境一致。

```text
Windows 可以运行 Golden 检查，
但禁止在 Windows 上更新 canonical baseline。
```

否则会引入字体抗锯齿与 Skia 渲染差异。baseline 生成/更新只走 `.github/workflows/golden-baselines.yml`（手动触发，Linux 环境）。

## 5. 字体限制

当前 pubspec 只打包 `NotoSansCJKsc-Regular.otf`（w400），没有 Medium/Semibold/Bold 独立字重文件。

### Golden 能确认

- 中文 glyph 正常
- 字符宽度和换行进入真实字体路径
- 文本区域、行数、spacing、overflow

### Golden 不能声称确认

- w600 / w700 的真实字体文件效果（当前为系统合成）
- 不同 Android OEM 的最终字形 rasterization
- Emoji fallback 的跨平台像素一致性

### Emoji 特别规则

**不要把系统 Emoji glyph 作为 Golden 核心比较对象**（Noto Color Emoji / Segoe UI Emoji / Apple Color Emoji 跨平台不同）：

- Emoji 面板结构 → Widget test
- App 自己的 sticker / image → 可以 Golden
- 原生 Unicode emoji → 不作为严格像素依据

## 6. Material Icons 限制

headless 环境可能出现 icon 字形缺失（已有真实案例）。处理流程：

1. Widget test 验证 Icon widget / semantic 存在
2. production screenshot 验证真实显示
3. 不把 headless 空 glyph 错判成产品 bug

**禁止反向忽略所有 icon mismatch**——只有确认是 headless 渲染限制才能走以上流程。

## 7. 每次 UI PR 证据

最低要求：

```text
before
after
viewport
state
tests
P0–P3 findings
```

redesign 追加：

```text
focused region
dark mode
large text
```

## 8. Golden 更新规则

只能在以下两个条件**同时**满足时更新：

```text
视觉变化是 deliberate（有意为之）
+
Design QA 通过
```

执行：

```bash
flutter test test/goldens --update-goldens
```

**禁止**：

```text
Golden 挂了
→ 直接 --update-goldens
→ 提交
```

这是整个视觉回归体系最重要的纪律。