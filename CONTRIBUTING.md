# 贡献指南

## 开始前

1. 阅读 [开发与交付规范](DEVELOPMENT_STANDARD.md)。
2. 阅读受影响模块的 README、接口说明和已有测试。
3. Flutter UI 改动先阅读 [设计文档导航](docs/design/README.md) 及适用的设计规范。
4. 先确认工作区状态和任务范围，不覆盖其他任务的未提交修改。

涉及个人教务、认证、安全中心、上传、MCP、数据库迁移或隐私边界的改动，按开发与交付规范的 R2/R3 要求执行，并先确认对应的架构、数据台账和发布约束。

## 本地检查

先执行受影响模块的定向检查；候选发布或高风险改动再执行模块级或全量检查。命令以模块 README、锁文件和 CI 为准。

### Flutter 客户端

~~~bash
cd client
flutter pub get
flutter analyze
flutter test --reporter compact
~~~

### Go 服务端

~~~bash
cd server
go vet ./...
go test ./...
go build ./...
~~~

涉及并发、共享状态或请求取消时，补充适用的 go test -race；涉及数据库、迁移或上传时，只能在隔离的可丢弃测试环境执行集成检查。

### Python 服务

~~~bash
cd python-rag-service
python -m compileall -q .
python -m pytest -q
~~~

python-edu-service 按其模块 README 执行。涉及外部学校系统或付费 AI 服务时，使用隔离配置和测试夹具，不发送真实用户请求。

### Web 与扩展

~~~bash
pnpm install --frozen-lockfile
pnpm -r check
pnpm test
pnpm -r build
pnpm assistant:dev
~~~

`pnpm assistant:dev` 为本地 5173 产出开发通道教务助手包到 `web/public/assistant/`，用于验证页面内的下载引导与免刷新复检；`pnpm -r build` 会为生产通道产出同一目录。该目录是构建产物，已列入 `.gitignore`，不得提交。

只在相关端或共享契约受影响时执行 Playwright 和扩展专项检查。

## 验收记录

每次功能或 Bug 修复至少记录一条真实用户链路，并覆盖适用的加载、空数据、失败、重试、权限、重复提交、账号切换和恢复状态。记录命令、环境、结果、跳过原因和未验证范围，不能只写“已测试”。

## 提交与外部动作

- 保持修改范围聚焦，不把无关格式化混入提交。
- 中文注释解释设计原因和关键边界，不写重复的教学说明。
- 不提交真实账号、密码、Cookie、Token、生产日志、个人教务数据或临时抓取结果。
- 变更隐私、认证、部署或迁移状态时，同步更新对应文档和测试。
- 未经明确授权不推送、不重写历史、不强推、不部署。

Git 暂存、提交前差异检查、禁止提交项和大文件规则统一见 [Git 提交规则](docs/git-submit-rules.md)。

生产部署、回滚和发布流程统一以 [部署总入口](DEPLOY.md)、[运维文档](docs/ops/) 和 [发布前回归清单](RELEASE_CHECKLIST.md) 为准。
