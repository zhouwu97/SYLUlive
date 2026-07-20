# 沈理校园客户端 AI 全阶段实施总结

更新时间：2026-07-20

## 1. 完成范围

本次工作承接阶段五成果，补齐阶段 3.1、阶段四至阶段八的客户端主线，并保留原有校园公开问答 SSE 链路。

### 阶段 3.1：保险箱恢复

- `IoPersonalSnapshotFileBackend` 在读取前检查限定目录内的 `.bak`/`.tmp`。
- 目标文件缺失且只有一个合法备份时恢复；目标存在时以目标为准并清理残留；多个备份或异常文件失败关闭。
- 恢复后仍由上层 AES-GCM 认证流程校验，临时文件不会被视为密文。

### 阶段四：只读个人数据链路

- `PersonalDataGateway` 绑定 App 用户指纹和教务来源学号，不接受模型提供的用户标识。
- 课表、成绩、体测、二课均通过加密快照 Store 读取，Gateway 只返回 typed overview/records 和新鲜度证据。
- 成绩和学业情况的成功响应在账号/学号上下文完整时写入 AES-GCM；上下文未就绪时页面保留本次结果，AI Gateway 不读取未落盘数据。
- 课表课程、隐藏项、学期起点和存档优先走 `ScheduleCacheStore`；体测不再写明文 `SharedPreferences`。
- 账号切换由根 Provider 同步，立即清理旧内存状态；旧明文缓存只能清理，不能猜测归属迁移。
- 移除了课表向 Download 目录写入明文 JSON 的自动备份。

### 阶段五：低风险 Skill

已实现并保留固定 Registry：今日/本周课表、学业概览、体测概览、二课概览、公开竞赛检索。每个成功个人结果必须带来源、抓取时间、过期时间和状态证据。

### 阶段六：权限预览与 Tool Calling

- `LocalToolCallValidator` 对 Tool ID、参数白名单、日期范围、结果数量和敏感字段递归校验。
- `LocalToolLoop` 限制三轮 Tool、三个个人 Skill、单次十秒、单结果 8000 字符；支持取消令牌、账号代际校验、重复/递归调用拒绝和超时失败关闭。
- 校园公共模型只能使用公开 Tool；个人 Tool 只能路由到用户配置的 OpenAI 兼容模型。
- 权限按敏感等级处理：低敏感支持会话授权，中敏感及以上只允许本次授权。
- API Key 只从 `FlutterSecureStorage` 读取；审计只记录 Tool、授权、Provider、数据类型和状态，不记录个人数值或请求正文。
- 权限预览 Dialog 展示数据类别、排除项、目标模型、更新时间和输出字段。
- Tool Loop 同时验证 Registry 和本轮下发 Definition，功能开关隐藏的 Tool 无法被模型伪造调用。

### 阶段七：确定性引擎

- `AcademicCalculationEngine`：固定 `sylu-gpa-v1` 公式、重修最佳尝试、纳入/排除课程、缺失学分和不可解析成绩。
- `GraduationRequirementEngine`：版本化规则包、来源元数据和 `completed/notCompleted/unknown/blocked/notApplicable` 五态。
- `CompetitionFitEngine`：硬资格过滤、学校认定和证据质量排序；`strong_recommendation_ready=false` 时禁止强推荐。
- `FitnessWeeklyPlanEngine`：`who-bmi-v1`、时间窗口、每周最多三次、训练间隔、轻/中强度和不适安全降级。
- 新增 `personal.academic.gpa`、`personal.academic.credit_summary`、`personal.academic.failure_risk`、`personal.graduation.readiness`、`personal.competition.fit`、`personal.fitness.weekly_plan`。

### 阶段八：产品化

- AI 页面新增“校园问答 / 个人助手”分段入口和六个快捷问题。
- 个人回答显示可展开的来源、时间和计算证据卡片。
- 新增模型设置、个人数据保险箱、毕业清单和 AI 功能开关页面。
- 数据中心支持查看当前账号/来源指纹、各数据状态、清除当前账号数据、清除全部个人 Vault 和审计记录。
- 个人模型不可用、未绑定教务、权限取消、账号切换或开关关闭时均明确失败，不回退到其他账号数据。

## 2. 关键安全边界

```text
公开问答 -> 服务端 SSE/RAG -> 仅公开内容
个人问题 -> 本地 Tool 校验 -> 权限预览 -> 固定 Skill -> Gateway -> 加密快照
成绩/GPA/毕业/竞赛资格/BMI -> 纯 Dart 确定性代码
模型 -> 只能理解问题、提出固定 Tool、解释已验证结果
```

客户端 AI 层不持有数据库连接、SharedPreferences、Secure Storage、Vault 路径、密码、Cookie、完整 Token、学号查询能力或任意用户 ID 查询能力。

## 3. 验证结果

- AI Runtime 定向测试：35 项通过。
- `.bak`/`.tmp` 保险箱恢复测试：4 项通过。
- 全量 `flutter test --no-pub`：632 项通过。
- 全量 `flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos`：无 error；仓库既有 418 条 warning/info。
- `git diff --check`：无空白错误，仅报告工作树原有 LF/CRLF 转换提示。
- 个人 AI 目录及相关 Provider 敏感字段、日志扫描：无命中。

## 4. 运行与发布注意事项

1. 个人助手要求已登录、教务来源学号已加载、个人 Gateway/Skills/Tool Calling 开关开启，并已保存 OpenAI 兼容模型配置。
2. 没有已人工审核的培养方案规则包时，毕业清单保持 `blocked/unknown`，不会生成确定性毕业结论。
3. 课表分钟级空闲时间尚未在快照模型中结构化；运动 Skill 在信息不足时保守地只使用无课日期窗口并降为轻强度。
4. 真机发布前仍需执行 Android 登录、账号切换、删除 Vault、网络断开和自定义模型 HTTPS 连接的人工冒烟测试。
5. 既有工作树包含服务端、部署和 RAG 相关未提交改动，本报告只覆盖本次客户端 AI 主线，不对无关改动作回退或重构。
