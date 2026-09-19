# 沈理校园迁移期教务兼容服务

这是一个 FastAPI 服务，负责迁移期的教务兼容能力和公开校园信息同步。它不是新版客户端的默认个人教务路径，也不应被当作长期的学校权限代理。

## 当前边界

- Docker Compose 内部端口为 `8000`，默认不直接发布到公网。
- `SCHOOL_AUTHORITY_RETIRED=true` 时，个人教务路由不加载，兼容入口返回 `410` 或不提供服务。
- 只有显式设置为 `false` 才会进入迁移/测试模式；生产是否启用必须以部署配置和发布审批为准。
- 迁移模式下的学校凭据、Cookie 和会话属于高风险数据，不能写入日志、调试输出或提交内容。
- 公开校园资讯路由可以独立运行，不等于恢复个人教务服务端代理能力。

## 本地运行

```bash
pip install -r requirements.txt
python main.py
```

默认配置来自 `config.py`：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `HOST` | `0.0.0.0` | 监听地址 |
| `PORT` | `8081` | 直接运行时的端口；Compose 使用 `8000` |
| `DATABASE_URL` | SQLite 本地文件 | 仅兼容模式初始化教务数据库 |
| `SCHOOL_AUTHORITY_RETIRED` | 未设置时 fail-closed | 是否退役个人教务能力 |

直接运行时访问 `http://localhost:8081/docs`；容器内部服务地址通常为 `http://python-edu-service:8000`。

## 路由状态

`/api/edu/*`、旧教务登录和个人教务抓取路由属于迁移期兼容能力，状态可能受 `SCHOOL_AUTHORITY_RETIRED` 与 Go 服务端的 `SCHOOL_ACADEMIC_ROUTES_RETIRED` 共同控制。对外文档请以 [`../server/API.md`](../server/API.md) 的 Active / Migration compatibility / Retired 标记为准。

公开校园信息同步、竞赛公开信息和探针脚本不应读取个人学校凭据。

## 测试与相关文档

```bash
pytest -q
```

- [仓库文档中心](../docs/README.md)
- [部署总入口](../DEPLOY.md)
- [后端 API 状态](../server/API.md)
