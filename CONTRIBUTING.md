# 贡献指南

## 开发前

先阅读文档中心、相关模块 README 和客户端设计规范。涉及个人教务、认证、安全中心、上传、MCP 或隐私边界的改动，应先确认对应的架构和发布约束。

## 本地检查

客户端：

~~~bash
cd client
flutter analyze
flutter test
~~~

服务端：

~~~bash
cd server
go vet ./...
go test ./...
go build ./...
~~~

RAG 和 MCP：

~~~bash
cd python-rag-service
pytest -q

cd ../_mcp
go test ./...
~~~

## 提交要求

- 保持修改范围聚焦，不把无关格式化混入提交。
- 中文注释解释设计原因和关键边界，不写重复的教学说明。
- 不提交真实账号、密码、Cookie、Token、生产日志、个人教务数据或临时抓取结果。
- 变更隐私、认证、部署或迁移状态时，同步更新对应文档和测试。
