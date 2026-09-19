# 快速验证清单

## ✅ 已修复文件列表

### Flutter 客户端
- [x] `client/lib/services/home_widget_service.dart`
  - 分离 `courseWidgetSchemaVersion = 2` 和 `examWidgetSchemaVersion = 2`
  - 更新所有引用

- [x] `client/lib/features/ai_device_bridge/device_tool_registry.dart`
  - 修复 freshness clamp: `clamp(1, ceiling)` 而非 `clamp(ceiling, 24*60*60)`

- [x] `client/lib/features/ai_device_bridge/device_tool_bridge_host.dart`
  - 二课刷新失败时，只在明确凭据失败时删除密码
  - 网络/解析失败保留密码并返回正确错误码

- [x] `client/lib/features/ai_device_bridge/device_tool_worker.dart`
  - 密码过期时本地重试：捕获 credential_unavailable → 弹窗输入 → 同一 job 重试

### iOS 原生
- [x] `client/ios/CourseScheduleWidget/CourseScheduleWidget.swift`
  - 考试小组件接受 schema 1-2：`version >= 1 && version <= 2`

### Android 原生
- [x] `client/android/app/src/main/kotlin/com/example/shenliyuan/ExamData.kt`
  - 考试小组件接受 schema 1-2：`if (version < 1 || version > 2) return WidgetExamData()`

### Go 后端
- [x] `server/internal/services/device_job_service.go`
  - 修复 freshness clamp: `if requested > maximum` 而非 `if requested < minimum`

- [x] `server/internal/handlers/canteen_dish_photo.go`
  - `SubmitDishPhoto` 返回 410 Gone

- [x] `server/internal/handlers/canteen_dish_submission.go`
  - `SubmitDishPhotoV2` 返回 410 Gone
  - `ResubmitDish` 返回 410 Gone

- [x] `server/internal/models/canteen_dish.go`
  - `MigratePendingDishesAndPhotos` 增加版本检查，只运行一次

---

## 🧪 快速测试命令

### 1. 考试小组件测试
```bash
# Flutter 写入测试数据
cd client
flutter run --dart-define=TEST_EXAM_WIDGET=true

# 在设备上添加考试小组件，确认显示正常
```

### 2. AI Freshness 测试
```bash
# 使用 curl 测试服务端 clamp
curl -X POST http://localhost:8080/api/ai/device-jobs \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{
    "tool_name": "device.academic.ensure_fresh_overview",
    "arguments": {"max_age_seconds": 60}
  }'

# 检查实际 clamp 后的值
```

### 3. 二课密码测试
```bash
# 模拟网络失败（关闭 WiFi）
# 触发二课刷新，检查密码是否保留

# 模拟密码错误（输入错误密码）
# 检查密码是否被删除
```

### 4. 密码过期本地重试测试
```bash
# 1. 保存一个旧的二课密码到本地
# 2. 在 AI 对话中请求：「帮我刷新二课数据」
# 3. 确认弹出密码输入框
# 4. 输入新的正确密码
# 5. 确认同一个 AI 请求成功完成（不需要重新发起）
```

### 5. 旧投稿 API 测试
```bash
# 测试旧 API 返回 410
curl -X POST http://localhost:8080/api/canteens/1/dish-photos \
  -H "Authorization: Bearer YOUR_TOKEN"

# 预期响应：
# {"code":"dish_submission_retired","error":"菜品与实拍现已通过食堂评价提交，请更新客户端"}
```

### 6. 迁移幂等性测试
```bash
# 重启服务器 3 次
go run ./cmd/main.go
# Ctrl+C
go run ./cmd/main.go
# Ctrl+C
go run ./cmd/main.go

# 检查数据库
psql -d shenliyuan -c "SELECT * FROM app_schema_migrations WHERE version = '20260825_01_canteen_pending_dish_migration';"

# 预期：只有一条记录
```

---

## 📊 修复前后对比

### 考试小组件
| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| Flutter 写入 schema | 2 | 2 |
| Android 读取 | ❌ 空（只接受 1） | ✅ 正常显示 |
| iOS 读取 | ❌ 空（只接受 1） | ✅ 正常显示 |

### AI Freshness
| 请求值 | 修复前（错误） | 修复后（正确） |
|--------|---------------|---------------|
| academic 60s | 300s ❌ | 60s ✅ |
| academic 300s | 300s | 300s |
| academic 86400s | 86400s ❌ | 300s ✅ |
| schedule 86400s | 86400s ❌ | 600s ✅ |
| erke 86400s | 86400s ❌ | 1800s ✅ |

### 二课密码保留
| 失败原因 | 修复前 | 修复后 |
|----------|--------|--------|
| 网络断开 | 删除密码 ❌ | 保留密码 ✅ |
| WebVPN 超时 | 删除密码 ❌ | 保留密码 ✅ |
| 页面解析失败 | 删除密码 ❌ | 保留密码 ✅ |
| 密码错误 | 删除密码 | 删除密码 ✅ |

### 密码过期后续跑
| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 使用旧密码刷新 | Job failed，AI Run 结束 ❌ | 弹窗输入新密码 ✅ |
| 输入新密码 | 需要重新发起 AI 请求 ❌ | 同一 Job 继续，AI Run 完成 ✅ |

### 旧投稿 API
| API | 修复前 | 修复后 |
|-----|--------|--------|
| POST /dish-photos | 创建 pending ❌ | 410 Gone ✅ |
| POST /dish-submissions | 创建 pending ❌ | 410 Gone ✅ |
| POST /resubmit | 创建 pending ❌ | 410 Gone ✅ |

### 迁移执行
| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 首次启动 | 执行迁移 | 执行迁移 ✅ |
| 第二次启动 | 再次执行 ❌ | 跳过 ✅ |
| 第 N 次启动 | 每次执行 ❌ | 跳过 ✅ |

---

## 🚨 注意事项

1. **部署顺序**：建议先部署后端（旧 API 返回 410），再部署客户端
2. **测试覆盖**：至少在一台 Android 和一台 iOS 设备上测试考试小组件
3. **数据库备份**：首次运行新的迁移逻辑前，建议备份 `canteen_dishes` 和 `canteen_dish_photos` 表
4. **监控告警**：部署后监控 410 错误数量，如果持续增加说明有大量旧客户端需要更新
5. **密码重试测试**：确保在真实网络环境下测试密码过期重试流程

---

## 📝 文档

- 详细分析：`FIXES_20260828.md`
- 提交信息：`COMMIT_MESSAGE.txt`
- 本清单：`VERIFICATION_CHECKLIST.md`

---

## ✅ 修复汇总

本次共修复 **6 个 P0 级关键问题**：

1. ✅ 考试小组件 schema 版本冲突
2. ✅ AI freshness 上限逻辑写反
3. ✅ 二课密码失败后错误分类
4. ✅ 旧菜品投稿 API 死链
5. ✅ MigratePendingDishesAndPhotos 重复运行
6. ✅ 密码过期后 Device Job 本地重试

**所有修复均已完成，建议在下一版部署前验证。**
