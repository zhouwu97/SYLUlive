# 政策 RAG 共享评测数据

本目录是 Go 评测 Runner 与后续 Python LangChain 测试的唯一评测数据源。每个
`.jsonl` 文件一行一个用例，并共同遵循 `schema.json`；禁止在 Python 侧复制或改写
字段语义。

## 文件

- `citation_validation.jsonl`：保留既有引用白名单与格式用例。
- `policy_quality.jsonl`：政策检索、生成、拒答和安全用例。
- `schema.json`：版本化输入契约，当前为 v1。

## 运行模式

- `fixture`：默认模式，只读取用例内的 `fixture`，不读取环境变量，不连接数据库、
  RAG 服务或模型 Provider。该模式用于验证评测数据、Runner 和固定输出，可复现但不
  代表线上服务的实时质量。
- `live`：必须显式传入 `--mode live`，并提供 CLI 报错中列出的数据库、RAG 服务和
  Provider 配置。该模式复用生产接口做只读评测，缺少依赖时必须非零退出。

失败报告只写公开用例 ID 和类型化原因，不写完整问题、模型回答、密钥或连接串。
