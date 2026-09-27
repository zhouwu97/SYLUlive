# AGENTS.md

所有任务先阅读 [DEVELOPMENT_STANDARD.md](DEVELOPMENT_STANDARD.md) 和 [CONTRIBUTING.md](CONTRIBUTING.md)，再按受影响模块读取对应 README、测试和运维文档。遵守最小修改范围，保留工作区中与本任务无关的修改；未经明确授权不推送、重写历史、修改仓库权限或执行生产操作。

## Flutter UI、设计、交互和动效

涉及 client/ 下的 Flutter UI、设计、交互或动效时：

- 阅读并遵守 skills/sylulive-design-engineering/SKILL.md。
- 设计权威文件为：
  - docs/design/DESIGN_SYSTEM.md
  - docs/design/MOTION.md
  - docs/design/ACCESSIBILITY.md
  - docs/design/DESIGN_QA.md
- 不得静默绕过 docs/design/adr/ 中已接受的 ADR。
- 必须验证 loading、empty、error、retry、权限、异步竞态和真实渲染状态；具体门禁按 DEVELOPMENT_STANDARD.md 执行。

## 其他模块

服务端、Python、Web、扩展、部署和隐私改动按 DEVELOPMENT_STANDARD.md 的风险分级和验证流程执行，并以 DEPLOY.md、docs/ops/、隐私台账和模块 README 作为对应操作入口。
