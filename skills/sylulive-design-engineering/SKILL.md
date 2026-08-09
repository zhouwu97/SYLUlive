---
name: sylulive-design-engineering
description: >
  Audit, design, implement, and verify Flutter UI changes
  in SYLUlive while respecting the repository design system,
  motion rules, interaction state, accessibility, and visual QA.
---

# SYLUlive Design Engineering

Audit → design → implement → verify Flutter UI 变更的工作流 skill。
收到任何「重新设计/优化/迁移 XXX 页面」类任务时必须走完本流程，
**禁止跳过 Recon 直接写 Dart**。

## Step 1：必须先读

顺序固定：

1. `docs/design/DESIGN_SYSTEM.md`
2. `docs/design/MOTION.md`
3. `docs/design/ACCESSIBILITY.md`
4. `docs/design/DESIGN_QA.md`
5. 相关 ADR（`docs/design/adr/`）

## Step 2：Recon

动页面之前必须 inspect：

```text
target screen
parent screen
same-level sibling screen
AppTheme (lib/theme/AppTheme.dart)
CampusTheme（如被引用）
shared widgets
Provider / state model
existing tests
```

然后内部判断真正的输出问题维度：

```text
Visual
Interaction
Motion
Accessibility
Performance
```

确认哪个是真实问题，不要「整体优化」。

## Step 3：状态矩阵

先列出适用状态，再动手：

```text
idle / pressed / loading / success / error / disabled / empty
```

聊天类功能追加：

```text
sending / failed / retry / keyboard / emoji / media
```

不能只画正常状态。

## Step 4：Scope Guard

禁止（除非任务明确要求）：

```text
未经允许改全局品牌主色 / Theme seed
创造新 radius（需先改 DESIGN_SYSTEM.md radius 表）
创造第二套 AppMotion
为简单动画引入新依赖
把所有内容组套 Card
无目的加动画
越界重写业务逻辑（MessageProvider / API / database）
移除既有交互行为
```

## Step 5：Prototype gate

不是所有改动都要 prototype。只有同时满足：

```text
存在 >=2 个真正不同的布局/交互方向
且影响面高
```

才进入 prototype（最多 3 个候选，使用真实 token / 文字 / 交互 / 尺寸，promote 后删除）。
否则直接修改。

## Step 6：Implementation

优先序：

```text
reuse（existing token / widget / pattern）
↓
extend
↓
new abstraction
```

禁止反过来。

## Step 7：Verification

完成后至少：

```text
flutter analyze（相关文件）
targeted widget tests
golden（视觉有意义时）
overflow check
dark / large text（适用时）
```

按 `docs/design/DESIGN_QA.md` 输出 P0–P3 Design QA。

## Step 8：最终输出格式

最终报告必须包含：

```text
Changed
- ...

Preserved
- ...

Tests
- ...

Design QA
P0:
P1:
P2:
P3:

Deferred
- ...
```

禁止输出「已经优化完成，UI 更现代了」这类无证据结论。