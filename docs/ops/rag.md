# RAG 部署

python-rag-service 处理校园公共知识检索和生成能力，Compose 内部端口为 8001。它不接触学校个人凭据、Cookie、用户数据库或原始个人教务响应。

~~~bash
cd python-rag-service
pytest -q
uvicorn app.main:app --host 127.0.0.1 --port 8001
~~~

生产启用前复核 RAG_SERVICE_TOKEN、模型版本、embedding 维度、超时、并发和外部模型提供方白名单。知识库发布遵循 knowledge-base/README.md 的版本与审核规则。
