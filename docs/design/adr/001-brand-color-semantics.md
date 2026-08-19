# ADR-001：品牌色语义

- 状态：**已接受（Accepted）**
- 日期：2026-08-09
- 决策者：项目负责人（SYLUlive）

## Context

当前代码存在两套「品牌感」来源且已经混合：

1. `AppTheme.AppTheme`：`ColorScheme.fromSeed(#6366F1 靛蓝)` 决定所有 Material 组件（Button / Switch / FAB / Navigation / Dialog action / Input focus / state layer）的 primary。
2. `CampusTheme`（青绿 `#147C72` + 暖白 `#FFFAF4`）实际上已经承担产品 Shell：`AppTheme.scaffoldBackgroundColor` / `canvasColor` 直接取 `CampusTheme.bg/darkBg`；`AppPageAppBar` 使用 `CampusTheme.pageBackground`；新页面的 Design QA 均以「品牌绿色」为准。

而「Campus」并不是真正隔离的业务子产品——SYLUlive 本身就是校园 App。所谓「CampusTheme 只是模块色」的框架与现实不符：**青绿色已经在承担产品 Shell 的身份，靛蓝仍偷偷控制默认 Material 组件**。

## 决策

```
#147C72（青绿）   = brandPrimary（全局品牌主色）
#6366F1（靛蓝）  = accentIndigo / legacyMaterialSeed（历史 seed，次强调色）
#8B5CF6（紫）    = accentPurple（次级强调）
#EC4899（粉）    = accentPink（次级强调）
```

约束：

- `#6366F1` 命名为 `accentIndigo`（或 `legacyMaterialSeed`），**不得命名为 `aiPrimary`**——除非未来明确决定 AI 模块与品牌无关地使用它。
- 迁移期间 `ColorScheme.fromSeed(#6366F1)` 可暂存作为兼容；这是登记的 known debt（见 `DESIGN_SYSTEM.md` §11 #4），不是永久状态。
- **禁止**任何新 Feature 引入第三个全局品牌主色候选。

## 备选方案

1. 靛蓝全局，绿色只做 Campus 模块色 —— 否决。与真实 Shell 行为矛盾（全局背景/二级页已经全绿），强行切割会造成持续的不一致性。
2. 双品牌双语境 —— 否决。SYLUlive 单体 App 不需要双品牌；只会让 AI 与开发者更难判断。
3. 立即全局切 seed —— **推迟**。`fromSeed` 切换会瞬间影响所有使用 `colorScheme.primary` 的组件（按钮/Switch/Checkbox/Radio/FAB/Navigation/Dialog action/Input focus/state layer），这是一次全 App 视觉迁移，不是 Foundation PR 的职责；必须在 PR2 QA/Golden 基建就绪后于 **PR5 Theme Semantic Convergence** 落地。

## 迁移路径

| 阶段 | 动作 |
| --- | --- |
| PR1 | 冻结本决策（已交付 `6b79d23f`）。`AppColors` 等 token 文件属 **Foundation implementation debt**，随 PR4/PR5 落地；`ColorScheme` 仍由 legacy seed 生成（写为 known debt） |
| PR1–PR4 | 各模块迁移只使用语义 token，不动 seed |
| PR5 | `ColorScheme.fromSeed(AppColors.brandPrimary)` + 全 App 视觉迁移，由 Golden diff 验收 |

## 影响

- 设计 token：`AppColors.brandPrimary` 成为全局唯一品牌入口。
- QA：PR5 的视觉 diff 覆盖 matrix：360×800 light / 390×844 light / 360×800 dark / 360×800 large-text（详见 docs/design/DESIGN_QA.md）。
- 无运行时破坏：本决策只冻结语义，不改变任何运行时行为。