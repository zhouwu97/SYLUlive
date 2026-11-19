# 迁移期教务服务

python-edu-service 的 Compose 内部端口为 8000，直接运行时默认端口为 8081。它是迁移期兼容组件，不是新版客户端个人教务的默认架构。

生产使用前必须明确设置 SCHOOL_AUTHORITY_RETIRED，并确认 Go 服务端的 SCHOOL_ACADEMIC_ROUTES_RETIRED 与客户端 capability 探测一致。个人教务路由退役后，客户端必须停止重试，不得只依赖服务端反复返回 410。

~~~bash
cd python-edu-service
pytest -q
~~~

学校密码、Cookie、Token 和原始 HTML 不得进入日志、RAG、MCP、备份或发布产物。

海外部署的本科核验沿用受限国内通道 `CAMPUS_CRAWLER_PROXY`，仅在学校爬虫客户端内配置代理。检查代理 CONNECT 连通性、学校证书链和域名校验。学校当前漏发的公开中间证书随 Python 服务 `certs/` 部署，验证必须到达系统可信根。直接连接超时或证书链错误应修复网络／证书链，保持 TLS 证书验证开启。

## Compose 兼容库迁移

新实例将 SQLite 写入独立命名卷 `edu_database`。已有实例使用旧容器内的默认库 `/app/database/edu.db` 时，须在首次按新配置重建容器前完成下面的迁移。使用原 Compose 项目名和生产环境文件，以匹配原服务和目标卷。首次安装可直接启动。

先停止旧服务，保留旧容器。以下命令将数据库及 SQLite 日志从停止的容器直接传入卷内的临时目录，验证完整性后再启用。目标已有数据库时命令会停止。复制失败时，旧容器可用 `docker start "$old"` 恢复服务。

~~~bash
set -euo pipefail
old=$(docker compose ps -aq python-edu-service)
test -n "$old"
docker compose stop python-edu-service
docker cp "$old:/app/database/." - | docker compose run --rm --no-deps -T --entrypoint sh python-edu-service -ec '
  cd /var/lib/sylulive-edu
  test ! -e edu.db
  umask 077
  stage=$(mktemp -d .import-XXXXXX)
  trap "rm -rf -- \"$stage\"" EXIT
  tar -xf - -C "$stage" --wildcards --no-anchored "edu.db*"
  test -s "$stage/edu.db"
  python - "$stage/edu.db" <<PY
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
mode = db.execute("PRAGMA journal_mode=DELETE").fetchone()
checks = db.execute("PRAGMA quick_check").fetchall()
db.close()
if mode != ("delete",) or checks != [("ok",)]:
    sys.exit("SQLite 完整性检查失败")
PY
  chmod 600 "$stage/edu.db"
  mv "$stage/edu.db" edu.db
'
docker compose up -d --build --no-deps python-edu-service
~~~

迁移后检查服务启动和原有绑定状态。后续容器重建复用同一项目的命名卷；执行 `docker compose down -v` 会删除该卷。
