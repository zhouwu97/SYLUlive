# 阶段 4B.1：退役服务端课表缓存

## 目标与边界

阶段 4B 已将课表写入客户端账号隔离的 AES-256-GCM 个人数据保险箱。本阶段彻底
退役旧的服务端课程副本，避免客户端 Vault 与服务端缓存成为两套个人数据来源。

本阶段保留按需课表抓取：

```text
客户端 -> Go /api/edu/courses -> Python /api/edu/courses/fetch -> 教务系统
```

响应只用于当前请求，客户端随后写入本机 Vault。服务端不会将课程、教师、地点、周次
或自定义课程持久化，也不会在日志中记录这些字段。

本阶段不包含 Personal Skill、Tool Calling、权限预览、模型个人数据发送、GPA 或毕业
判断，也不修改客户端 Vault 或 Gateway 协议。

## 退役行为

Go 层保留以下旧路径仅用于兼容旧客户端：

```text
GET  /api/edu/courses/local
POST /api/edu/courses/sync
```

它们始终返回：

```json
{
  "code": "COURSE_CACHE_RETIRED",
  "error": "服务器课表缓存已退役，请升级客户端后重新同步课表",
  "action": "upgrade_client",
  "retryable": false
}
```

Python 服务对旧 `sync`、`local`、手动课程、自定义、更新和删除课程路径执行相同的
410 响应，且不注入数据库会话。旧 `PythonScheduleCacheReader`、服务端
`ScheduleSkill`、`get_my_schedule_windows` Tool 和相应评测夹具均已移除。AI 能力响应
继续保留 `schedule_windows: false`，不会意外对旧客户端宣称该能力可用。

## 历史数据清理

Python 服务启动时会通过固定白名单依次清空：

```text
courses_custom
courses_raw
```

缺失表按空表处理，避免新部署因旧表不存在而启动失败。表名不可由请求或配置输入，且
只执行 `DELETE`，不会触碰教务绑定、成绩或其他业务表。需要人工补跑时，在已配置生产
数据库凭据的环境中执行：

```bash
cd python-edu-service
python scripts/retire_course_cache.py
```

该脚本会输出每张退役表删除的记录数；实际生产清理由部署者在目标数据库上执行。

## 验证

```powershell
cd server
gofmt -w cmd/main.go internal/handlers/edu.go internal/handlers/ai_capabilities.go `
  internal/handlers/edu_course_cache_retirement_test.go internal/ai/tool_registry.go `
  internal/ai/eval.go
go test ./...
go vet ./...

cd ..\python-edu-service
python -m compileall -q .
python -m pytest -q

cd ..
git diff --check
# 旧路径会保留为 410，因此只确认不再存在缓存读取器、服务端 Skill 和旧迁移脚本。
$legacyReferences = rg -n "PythonScheduleCacheReader|ScheduleSkill|migrate_course_terms" `
  server python-edu-service --glob "*.go" --glob "*.py"
if ($LASTEXITCODE -eq 0) {
  throw "发现未退役的服务端课表缓存引用: $legacyReferences"
}
if ($LASTEXITCODE -gt 1) {
  throw "退役引用扫描失败，退出码: $LASTEXITCODE"
}
```

回归测试覆盖旧读取和上传均返回 410、Python 旧写入路径不可用、内部认证仍有效、历史
缓存表清理不会影响无关表，以及 AI 能力不暴露已退役的服务端课表 Skill。

## 本地验证结果

本阶段完成时已执行：

```text
server/go test ./...                         PASS
server/go vet ./...                          PASS
python-edu-service/python -m compileall -q . PASS
python-edu-service/python -m pytest -q       174 passed
client/flutter test --no-pub                  611 passed
client/flutter analyze                        0 errors
git diff --check                              PASS
```

客户端静态分析仍报告仓库既有的非致命 warning 和 info；本阶段没有修改客户端源文件。
