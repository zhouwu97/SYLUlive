# Git 提交规则

## 提交前检查

每次提交前先执行：

```bash
git status --short
git diff --stat
git diff --cached --stat
```

只提交本次任务相关文件。看到不认识的新增文件、构建产物、缓存目录、密钥文件或大二进制时，先停下来确认，不要顺手 `git add .`。

## 禁止提交

- Flutter/Android 构建产物：`client/build/`、`client/.dart_tool/`、`client/android/.gradle/`
- 本地打包文件：`*.apk`、`*.aab`
- 后端本地编译文件：`server/*.exe`、`server/*.exe~`
- 本地环境与密钥：`.env`、`key.properties`、`*.jks`
- IDE/Agent 本地目录：`.idea/`、`.agents/`、`.claude/`、`.codex/`、`.sisyphus/`
- Python 缓存与探测输出：`__pycache__/`、`.pytest_cache/`、`python-edu-service/tools/*/output/`
- 崩溃与调试日志：`*.log`、`hs_err_pid*.log`、`replay_pid*.log`
- 临时备份和历史产物：`backups.tar/`、`before-low-conflict-cleanup.txt`

## 可以提交

- 业务源码、配置模板、迁移脚本、测试代码和项目文档
- 必须进入仓库的静态资源，例如正式使用的图片、字体、JSON 数据
- 新增依赖配置，但要确认不是本机路径或私密配置

## 分阶段暂存

优先使用精确路径暂存：

```bash
git add client/lib/screens/example.dart
git add server/internal/handlers/example.go
```

需要挑选部分代码时使用：

```bash
git add -p
```

除非已经确认工作区只有本次任务相关改动，否则不要使用：

```bash
git add .
git add -A
```

## 大文件规则

单个新增文件超过 10MB 时必须确认用途。构建产物、备份、数据库、二进制可执行文件不要提交；确实需要长期版本管理的大资源，应先说明原因并考虑 Git LFS 或外部发布渠道。
