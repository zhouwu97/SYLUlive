# SYLUlive 设计系统（Flutter 客户端）

- 状态：**冻结 v1**（2026-08-09）
- 适用范围：`client/` 全部 Flutter UI。本文是设计决策的执行合同——AI 助手与人工开发在修改任何 UI 前必须阅读本文、`MOTION.md` 与 `adr/`。
- 基线：`MCP` 分支当前 HEAD。
- 动效契约见 `MOTION.md`；设计 QA / Golden 协议在 PR2 作为 `DESIGN_QA.md` 落地；本文件只定义「是什么」。

## 1. 产品身份

口号：**克制、轻量、校园、友好、清晰、高频使用不疲劳。**

**不是**：SaaS Dashboard、iOS 克隆、二次元游戏 UI、营销落地页、玻璃拟态堆砌、悬浮卡片堆砌。

### 设计优先级（冲突时按此裁决）

1. 信息清晰
2. 操作效率
3. 一致性
4. 视觉精致
5. 装饰性

## 2. 品牌语义（详见 ADR-001）

| 角色 | 值 | 职责 |
| --- | --- | --- |
| `brandPrimary` | `#147C72` 青绿 | **唯一全局品牌主色** |
| `accentIndigo`（aka legacyMaterialSeed） | `#6366F1` | 历史 Material seed；次强调色。**禁止命名 aiPrimary** |
| `accentPurple` | `#8B5CF6` | 次级强调 |
| `accentPink` | `#EC4899` | 次级强调 |

- **暂态**：`ColorScheme.fromSeed(#6366F1)` 在 QA/Golden 基建就绪（PR5）前保持不变，这是登记的 known debt（§11-6）。
- 任何新 Feature 不得引入第三个「全局品牌主色」候选。

## 3. 色彩语义层（目标结构）

```
Global Token（品牌 + 中性色）
    ↓
Semantic Token（surface / text / border / feedback）
    ↓
Feature Token（competitionAccent / eduAccent / pollAccent）
    ↓
Component Token（组件内部派生）
```

### 全局中性色（允许直接引用）

| 语义 | Light | Dark |
| --- | --- | --- |
| `surfacePrimary`（页面背景） | `#FFFAF4` | `#111315` |
| `surfaceSecondary`（卡片/普通 surface） | `#FFFFFF` | `#1E2226` |
| `textPrimary` | `#1F2328` | 待 Dark audit |
| `textSecondary` | `#747B82` | 待 Dark audit |
| `borderNormal` | `#E2EFEA` | 待 Dark audit |
| `borderSubtle` | `#E8EEE9` | 待 Dark audit |

### 业务模块色（Feature Token）

允许 `competitionAccent` / `eduAccent` / `pollAccent` 存在，但必须建立在全局 token 之上，**不得重新定义**：页面背景、基础文字色、基础边框色、基础 Card 白。

### 业务功能色（保留）

`CampusTheme.blue #2F80ED` / `orange #F2994A` / `green #10B981` / `cyan #0EA5A4` / `red #E54848` 作为状态/业务色保留，语义在 PR5 token 化时逐一登记。

## 4. 圆角 Token（canonical）

| Name | 值 | 用途 |
| --- | --- | --- |
| `sm` | 8 | 行内元素、chip、小控件 |
| `md` | 12 | 普通控件（按钮、输入框、列表行） |
| `lg` | 16 | 独立交互 surface（Card、Dialog、FAB） |
| `sheet` | 24 | BottomSheet / 大型弹层顶部 |
| `pill` | 999 | 全圆角元素 |

原则：**不是所有东西都应该圆。** 信息行、Section、Setting 行优先用 spacing / divider / 背景色建立层级，只有真正独立的交互 surface 才使用明显圆角。

### 迁移映射（当前库存 → 目标）

| 当前值 | 目标 | 备注 |
| ---: | ---: | --- |
| 8 | 8 | 不变 |
| 10 | 12 | |
| 12 | 12 | 不变 |
| 14 | **16** | 主要是 FAB；统一为 lg |
| 16 | 16 | 不变 |
| 20 | 16 或 24 | 普通 Card → 16；大型 surface → 24（逐例裁定） |
| 24 | 24 | 不变 |

不做 6 档，当前代码无证据需要它。

## 5. 间距 Token（4px 基线）

| Name | 值 |
| --- | --- |
| xs | 4 |
| sm | 8 |
| md | 12 |
| lg | 16 |
| xl | 20 |
| xxl | 24 |
| section | 32 |

原则：不禁止 10/14/18，但常规页面不得**随机**创造间距——非标准值必须由布局需要解释。

## 6. 排版 Token

统一角色：`titleLarge/titleMedium/titleSmall`、`bodyLarge/bodyMedium/bodySmall`、`labelLarge/labelMedium/labelSmall`。

- **基础字体**：`NotoSansCJKsc`（唯一 family），emoji 走 fallback。
- **已知限制**：当前仅打包 `Regular`（w400）字重；w500/w600/w700 均为系统合成。Golden 与 QA 不承诺验证真实字重栅格化（登记于 §11）。
- 标题页 AppBar：17px / w700——目标统一（见 §8）。

**禁止**：在 widget 中到处写 `TextStyle(fontSize: 15, fontWeight: FontWeight.w600)` 这类魔法排版值；必须引用 token。

## 7. Surface 层级

| Level | 用途 |
| --- | --- |
| L0 | 页面背景（`#FFFAF4` / `#111315`） |
| L1 | 普通 surface（卡片、列表行） |
| L2 | 弹层 / BottomSheet / Dialog |
| L3 | Modal / 全屏覆盖 |

禁止：`Card > Card > Pill` 多层嵌套包装。内容组优先用 spacing 与 divider；只有真正需要独立表面语义才升级层级。

## 8. AppBar 契约（目标，PR5 落地）

| 项 | 值 |
| --- | --- |
| 高度 | **56px**（`AppPageAppBar` 现行值） |
| leadingWidth | 56 |
| 标题 | 17px / w700 / 居中 |
| 背景 | 跟随页面（`CampusTheme.pageBackground`） |
| elevation / scrolledUnder | 0 |

现状：`app_theme.dart` 的 `AppTheme.appBarTheme` 为 48px / w600；`AppPageAppBar` 为 56px / w700。统一目标 56/w700。

## 9. 触控（Accessibility 最低线）

- 高频触控目标 ≥ **44×44 logical px**；视觉元素可以只有 20×20，但命中区不得缩到 20×20。
- `VisualDensity.compact` 保留它「视觉紧凑」的意图，但**视觉紧凑 ≠ 交互区域紧凑**——后续重点审计 IconButton / Tab / nav / message actions / chips / toolbar actions。
- 最终完整无障碍契约（大字号、Reduced Motion、Screen Reader、对比度）在 PR2 `ACCESSIBILITY.md` 并随 PR5 验收。

## 10. AI / 人工修改 UI 前必须遵守

（PR2 将把此清单做成可执行的 agent skill；本文是规则的源头）

1. **不得**在未检查现有 token 的情况下发明新 accent 色。
2. **不得**为单个页面引入新 radius 值（新增 radius == 需要先改本表）。
3. **不得**把每个信息组包进 Card。
4. **不得**只为了让 UI 显得高级而加动画（先读 `MOTION.md` 频率分级）。
5. **不得**为简单动效引入新依赖（Flutter 原生即可）。
6. **不得**越界重设计任务范围外的组件。
7. **不得**移除既有交互行为，除非任务明确要求。
8. **不得**宣称页面完成而不验证 loading / error / empty 状态。

## 11. Known Debt Ledger（已知不一致登记表）

新增不一致时在此登记，禁止只靠口头约定。

| # | 不一致 | 现状 | 目标 | 处理 PR |
| --- | --- | --- | --- | --- |
| 1 | AppBar 高度 | Theme 48 / 二级页 56 | 56 | PR5 |
| 2 | AppBar 标题字重 | Theme w600 / 二级页 w700 | w700 | PR5 |
| 3 | Card 颜色 | `AppTheme.cardTheme` 未设 color → Material scheme.surface（非纯白）；`CampusTheme.card = #FFFFFF` 显式纯白 | 统一为一套 surface 语义 | PR5 |
| 4 | Seed 色 | `ColorScheme.fromSeed(#6366F1)`，与品牌 `#147C72` 不一致 | 品牌 seed | PR5（QA 就绪后） |
| 5 | 文件位置 | `utils/app_motion.dart` 在 utils，应归 `theme/` | `theme/app_motion.dart` | PR4 移动 + 收敛数值 |
| 6 | 动效魔法值 | chat 0/35/45/100/130/220ms 等 | AppMotion token | PR4 + PR3 顺带 |
| 7 | 字体字重 | 仅 Regular 单字重，w600/w700 合成 | 引入字重文件或明确已知限制 | 决策在 PR5 前 |
| 8 | FAB 圆角 | 14 | 16 | PR5 |
| 9 | 食堂 Feature Token | `CanteenTheme` 引入 `radiusSm=10 / radiusMd=14 / radiusLg=20`（偏离 canonical 8/12/16）且 feature 层重定义 page/text/border 中性色（`#F8F7F4`/`#202124`/`#EAE8E3`），违反「Feature Token 不得重定义全局中性色」 | 食堂视觉作为独立 Feature Token 收敛；radius 偏离属 deliberate（图片 14px、chip 10px），由食堂页面统一引用 `CanteenTheme`，不扩散到其他模块 | PR6 时评估是否将 10/14 提升为全局档位 |

## 12. 路线图（冻结）

| 顺序 | 内容 |
| --- | --- |
| Preflight | 工作区整理（处理未提交改动；基线干净） |
| PR1 | Design Foundation（已交付 `6b79d23f`）：文档冻结。`AppTheme.dart → app_theme.dart`、`utils/app_motion.dart → theme/app_motion.dart` 已完成机械迁移；AppColors / AppRadius / AppSpacing / AppTextStyles token 已落地，视觉切换仍属 PR5A-1 |
| PR2 | QA Infrastructure + AI Skill：Golden helpers、字体加载、viewport、DESIGN_QA 流程、PR checklist、sylulive-design skill |
| PR3 | Chat Pilot：私信列表/详情/composer/发送态；chat magic duration 迁移；Widget tests + Goldens |
| PR4A-0 | ✅ AppMotion 文件机械迁移：`utils/app_motion.dart → theme/app_motion.dart`，保留临时 deprecated shim；不改页面行为 |
| PR4A-1 | ✅ Motion Semantic Foundation：Amplitude Contract、`micro/tab/overlay/movement`、进入/退出曲线与 reduced-motion 规则；movement 最终曲线待真机 A/B |
| PR4A-2 | ✅ 高频路径 Motion Cleanup：首页 Root Tab / Feed / BottomNav；Chat Emoji 与 Scroll Intent 保持独立文件边界，可独立回滚 |
| PR4B-P | Gesture Prototype：A/B/C 三个 throwaway 方向，完成冲突矩阵与设备 feel-check 后再决定生产方案 |
| PR4B | Gesture Production：仅实现被 Prototype Gate 选中的 direct manipulation 方向 |
| PR5A-0 | ✅ Theme 文件/Token 机械迁移：`AppTheme.dart → app_theme.dart`、基础 token 文件；不切 seed、不改视觉行为 |
| PR5A-1 | ⏳ Theme Semantic Convergence：seed → brandPrimary、AppBar 48→56、Card/surface、radius 全局迁移；等待 Linux canonical Golden diff 后单独执行 |
| PR5B | Shell Primitives：BottomNav、SearchField、BottomSheetShell、SectionHeader、基础 Surface |
| PR6+ | Feature Migration：首页 Feed → 教务 → 竞赛/投票/集市 → 设置；Chat 会话列表另做独立视觉迁移 |

**设计工程完成后：新页面只要遵守本文件与 QA 流程，就不应明显跑偏——不依赖某个 AI、某次 prompt 或某人的临时审美。**
