# 2026-07-04 今日提交升级审计报告

审计时间：2026-07-04  
分支：`fwqtest`  
范围：`2026-07-04 00:00:00 +0800` 至当前 `HEAD=872b4106`  
基线：`acb891c`  
今日提交：41 个提交，88 个文件变更，约 7097 行新增、1869 行删除。

## 一、今日主要升级版块

### 1. 水区/水帖版块体系

升级内容：

- 新增版块关注模型与接口：`/api/water/sections/:slug/follow`、`/api/water/sections/followed`。
- `sort=following` 改为展示当前用户关注的水帖版块帖子。
- 新增版块内置顶、版块精华、首页精华申请衔接。
- 新增水区作者版块等级、称号、经验展示。
- 新增全站每日经验与版块每日经验发放。
- 新增版块等级称号管理 UI。
- 新增水区置顶摘要条，压缩置顶帖展示。
- 恢复水区分类 feed 帖子展示，并重构版块页密度。

整体判断：

水区从“分类帖子流”升级成了“可关注、可经营、可成长、可管理”的社区版块体系，这是今天最大的一组升级。后端模型、权限、前端展示基本成型，自动测试覆盖了一部分缓存、置顶、字段解析和 UI 表单链路。

### 2. 私信限制

升级内容：

- 服务端新增“陌生人首条私信”限制：对方未关注且未回复前，只允许发送 1 条消息。
- 客户端新增 send-state 查询和输入框锁定提示。
- 曾加入的“等级限制私信”已被回滚。

整体判断：

最终规则是合理的防骚扰策略：以“对方关注/回复”为解锁条件。客户端仍保留了等级限制 UI 分支，属于回滚后残留。

### 3. 集市发布与图片预览

升级内容：

- 发布表单大幅升级，新增商品描述标签、图片预览页、图片网格优化。
- 市场卡片新增字段展示与测试。
- 发布流程纳入 `1.5.29` 版本发布。

整体判断：

相关 Flutter 测试通过，发布表单和图片预览链路目前没有发现阻断问题。

### 4. 评分详情页

升级内容：

- 教师详情与专业详情页重新设计。
- 新增评分头部、评分面板、分布条、我的评分卡、评分输入弹层、政策提示等组件。

整体判断：

组件拆分清晰，视觉和交互密度比旧页面更统一。局部 analyze 仍有未使用变量和 async context lint，需要清理。

### 5. 校园页与其它 UI

升级内容：

- 校园页改为更高信息密度布局。
- 新增校园 header、新闻卡、服务网格、公告标签、主题常量等组件。
- 管理后台 AppBar/status bar overlay 做了修复。
- 设置页更新检查按钮高亮。
- Flutter layout diagnostics 文案和入口优化。

整体判断：

校园页重构后仍残留旧私有 widget 和未引用函数，属于重构后清理不彻底。

## 二、发现的问题

### P1 版块“精华”Tab 请求错接口，实际会拿全站精选

位置：

- `client/lib/providers/post_provider.dart:103-104`
- `server/internal/handlers/post.go:367-371`
- `server/internal/handlers/post_featured.go:53-72`

问题：

客户端只要 `sort == 'featured'` 就请求 `/posts/featured`。但今天新增的“版块精华”后端逻辑写在通用 `/posts?sort=featured&type=<section>` 分支里，会 join `water_section_featured_posts` 过滤当前版块。`/posts/featured` 只看 `posts.is_featured = true` 和 `board_id`，不处理 `type`，也不处理版块精华表。

影响：

用户进入某个水区版块点“精华”，看到的可能是全站水区/板块精选，而不是当前版块的精选；版主刚加精的版块帖子如果还没通过首页精选审核，也不会出现在该版块精华 Tab。

建议：

- 方案 A：客户端在带 `type` 的水区版块精选场景请求 `/posts`，让 `GetList` 的 section featured 分支生效。
- 方案 B：扩展 `/posts/featured` 支持 `type` 和 `water_section_featured_posts`。
- 补一个 PostProvider 单测：`sort=featured + type=course_study` 应请求 `/posts` 或确保服务端按 section 返回。

### P2 关注版块信息流缓存失效不完整

位置：

- `client/lib/providers/post_provider.dart:158-167`
- `client/lib/screens/water_category_feed_screen.dart:581-606`
- `client/lib/providers/water_section_provider.dart:193-204`

问题：

`invalidateFollowingFeed()` 只删除 key `1|following||`，而版块页实际使用的是 `1|following|<section_slug>|<tag_id>`。同时，版块页关注/取消关注按钮只调用 `WaterSectionProvider.toggleFollow()`，没有同步清理 PostProvider 的 following feed。

影响：

用户关注某版块后，切到该版块“关注”Tab 可能继续看到旧空列表；取消关注后也可能短时间看到旧数据。登录/退出时也只清全局 following key，不能覆盖分版块 following 状态。

建议：

- `invalidateFollowingFeed()` 支持清理所有 keyParts 中 sort 为 `following` 的状态。
- 关注/取消关注成功后立即调用 PostProvider 失效，并刷新当前 following tab。
- 补测试覆盖 `1|following|course_study|` 这类 key。

### P2 帖子缓存没有按版块/标签隔离，且未持久化新版水区元数据

位置：

- `client/lib/services/post_cache_service.dart:14-35`
- `client/lib/providers/post_provider.dart:171-178`
- `client/lib/models/post.dart:198-210`

问题：

缓存 key 只有 `boardId + sort`，没有 `type` 和 `tag_id`。水区现在强依赖版块页，多个版块同为 `board=1, sort=all/time/featured`，会共用缓存。并且缓存序列化目前只保存全站置顶/全站精选字段，没有保存：

- `water_section_pinned`
- `water_section_pin_id`
- `water_section_featured`
- `water_section_featured_id`
- `water_section_author_meta`
- `exp_earned`

影响：

冷启动或弱网时，用户切到 A 版块可能先看到 B 版块旧缓存；版块置顶、版块精华、作者版块等级徽标也会在缓存首屏阶段丢失，等网络回来才恢复。

建议：

- 缓存 key 升级为 `board + sort + type + tag_id`。
- `_postToJson` 补齐水区新版字段。
- 新增测试：不同 section 的缓存隔离；缓存恢复后水区置顶/精华/等级徽标不丢。

### P2 等级称号“留空沿用默认”语义不成立

位置：

- `client/lib/screens/water_section_manage_screen.dart:1209-1224`
- `client/lib/screens/water_section_manage_screen.dart:1253`
- `server/internal/handlers/water_section.go:973-1027`

问题：

UI 文案说“留空则沿用默认称号”，但保存时前端会把空输入替换成当前标题再提交；后端要求 title 非空，并删除该版块所有旧称号后重新创建提交的 rows。这样会导致：

- 留空不能清除自定义称号。
- 默认称号保存后会被写成 custom 记录。
- 以后无法区分“默认”与“自定义同名”。

影响：

版主以为自己恢复默认，实际数据库固化了一套自定义称号；后续默认文案调整也不会影响这些版块。

建议：

- 前端保留空值语义，提交空 title 或 `custom=false`。
- 后端允许某等级删除自定义记录，缺失时回落默认。
- 保存接口改为 patch/upsert 单项或支持 `{level, title, reset}`。

### P3 私信等级限制残留 UI 分支

位置：

- `client/lib/models/message_send_state.dart:28-29`
- `client/lib/screens/chat_detail_screen.dart:936`
- `client/lib/screens/chat_detail_screen.dart:998-1000`
- `server/internal/handlers/message.go:526-560`

问题：

服务端最终不会返回 `level_too_low`，但客户端还保留“你的等级不足3级”的提示分支。

影响：

当前不影响主链路，但后续排查私信策略时容易误解规则。

建议：

若近期不恢复等级门槛，移除客户端残留分支；若未来要恢复，应重新补服务端规则、错误码和测试。

### P3 今日改动文件仍有 analyze 清理项

局部 analyze 结果：

- `client/lib/screens/campus_screen.dart` 有 6 个旧私有 widget/函数未使用。
- `client/lib/screens/water_section_manage_screen.dart` 有未使用 import 和 async context lint。
- `client/lib/widgets/rating_detail/rating_item_card.dart` 有未使用变量 `primaryColor`。
- `client/lib/widgets/rating_detail/rating_input_sheet.dart` 有 async context lint。
- `client/lib/widgets/post_card.dart` 有不必要字符串插值。

影响：

不阻断运行，但会持续污染全量 analyze，让以后真正的错误更难被看见。

建议：

单独做一次“今日 UI 重构尾巴清理”，不要混进功能提交。

## 三、链路验证结果

已执行：

- `git log --since='2026-07-04 00:00:00 +0800' --until='2026-07-05 00:00:00 +0800'`
- `git diff --stat acb891c..HEAD`
- `go test ./...`：通过。
- `flutter test test/post_feed_isolation_test.dart test/profile_message_badge_state_test.dart test/screens/market_publish_form_test.dart test/widgets/market_post_card_test.dart test/screens/water_post_composer_ui_test.dart`：通过，21 个测试全部通过。
- `flutter analyze`：失败，438 个 warning/info，主要是历史 lint 噪声。
- 针对今日重点文件的 `flutter analyze ...`：失败，12 个问题，均为 warning/info 级别。

未覆盖：

- 未启动本地后端做真实 HTTP 联调。
- 未跑模拟器/真机手动点击链路。
- 未验证生产服务器。

## 四、逐链路结论

### 水区版块列表/详情

后端可选鉴权能返回 `is_followed`，前端可正常解析。基础链路可用。

风险：关注状态变更后 following feed 缓存未完整失效。

### 水区发帖/回复/经验

发帖和回复成功后会尝试发全站每日经验和版块每日经验，经验失败不阻断主流程。模型和测试没有发现编译问题。

风险：缓存没有保存 `exp_earned` 和作者版块等级元数据，弱网首屏体验会丢提示。

### 水区置顶/精华

版块置顶字段能解析，置顶摘要条测试通过。版块精华写入后端逻辑存在。

风险：版块精华 Tab 请求路径错误，是当前最需要优先修的功能问题。

### 关注版块动态

后端 `sort=following` 会按当前用户关注的 section slug 过滤帖子。

风险：缓存失效范围不完整，UI 上关注/取关后可能不立即反映。

### 私信限制

服务端最终规则清晰：对方未关注且未回复时，只允许一条首发消息。客户端有 send-state 查询和输入框锁定。

风险：等级限制文案残留，建议清理。

### 集市发布/图片预览

相关测试通过。未发现阻断问题。

风险：图片预览属于 UI 链路，仍建议真机检查多图、大图、删除/重排场景。

### 校园页/评分详情 UI

重构完成但存在未用代码和 lint。自动测试未覆盖视觉布局。

风险：需要真机看小屏滚动、输入弹层键盘遮挡和长文本溢出。

## 五、功能添加建议

1. 水区“我的版块等级卡”：在版块页 header 展示当前用户 Lv、经验进度、今日是否已拿经验，能直接强化成长反馈。
2. 版块关注聚合页：做一个“我关注的版块”入口，按版块分组展示最新帖和未读/新帖数。
3. 版块精华审核状态回显：版主加精后显示“已入版块精华 / 首页推荐待审核”，避免以为加精就等于首页精选。
4. 经验奖励 toast：发帖/回复成功时展示“全站 +10 / 版块 +10 / 升级到 Lv.X”，并支持在个人主页查看经验流水。
5. 版块管理仪表盘：每个版块展示今日发帖数、回复数、被举报数、禁言数、精华数，帮助版主管理。
6. 私信安全增强：加入“拉黑/举报/仅关注的人可私信我”等用户侧隐私开关。
7. 缓存健康测试：把 section/tag 维度、置顶/精华/等级元数据纳入缓存回归测试，防止水区体验在弱网下退化。

## 六、建议修复优先级

1. 先修 P1：版块精选请求路径/服务端过滤不一致。
2. 再修 P2：following feed 缓存失效、帖子缓存 key 和新版字段持久化。
3. 再修 P2：等级称号默认/自定义语义。
4. 最后做 P3 清理：私信等级残留、今日改动文件 analyze warning。

