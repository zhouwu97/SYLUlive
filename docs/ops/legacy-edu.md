# 迁移期教务服务

python-edu-service 的 Compose 内部端口为 8000，直接运行时默认端口为 8081。它是迁移期兼容组件，不是新版客户端个人教务的默认架构。

生产使用前必须明确设置 SCHOOL_AUTHORITY_RETIRED，并确认 Go 服务端的 SCHOOL_ACADEMIC_ROUTES_RETIRED 与客户端 capability 探测一致。个人教务路由退役后，客户端必须停止重试，不得只依赖服务端反复返回 410。

~~~bash
cd python-edu-service
pytest -q
~~~

学校密码、Cookie、Token 和原始 HTML 不得进入日志、RAG、MCP、备份或发布产物。
