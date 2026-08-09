# SYLUlive 无障碍契约（Accessibility）

- 状态：**冻结 v1**（2026-08-09）
- 定位：SYLUlive 真正要执行的短版契约，不是 WCAG 教材。详细交互场景（私信等）随对应 PR 补充。

## Touch

- 高频触控目标 ≥ 44×44 logical px
- 视觉元素可以只有 20×20，但命中区不得缩成 20×20
- `VisualDensity.compact` 保留「视觉紧凑」，但交互区域必须单独审计（IconButton / Tab / nav / message actions / chips / toolbar actions）

## Text

- 1.3× text scale 必测（canonical viewport `large-text`）
- 1.5× 作为高风险页面 overflow stress test
- 不允许关键按钮文字被裁掉

## Motion

- 使用 `MediaQuery.disableAnimationsOf(context)`
- reduced motion 下：保留 opacity / color 反馈；移除大距离位移 / scale / decorative stagger
- 完整规则见 `MOTION.md` §6

## Dark

- 所有 redesign 必测 dark mode
- 禁止只靠颜色表达状态（必须结合 icon / text / shape）

## Semantics

- 无文字 IconButton 必须有 tooltip 或 semantic label
- destructive action 必须明确语义（semanticLabel / dialog 文案）

## Contrast

- 品牌色不能替代错误/成功语义（错误、成功、警告必须有独立语义色）
- 品牌主色 `#147C72` 只承担品牌身份，不承担状态语义