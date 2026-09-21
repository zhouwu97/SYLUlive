package handlers

import "errors"

// 内容发布额度的检查实现已下沉到 services/content_publish_quota.go：
//
//   - 规则与阈值（发帖 5 分钟 6 条 / 24 小时 30 条；回复 10 分钟 30 条 / 24 小时
//     200 条；回复同帖同文本 1 分钟重复）保持不变。
//   - 原实现 `postRateLimited` / `replyRateLimited` 只返回 bool，把 Count 错误当作
//     0 次放行，并且把“检查”和“写入”拆在事务之外，并发下会超发。
//   - 现在由 services.LockUserForContentWrite + services.CheckPostPublishQuota /
//     CheckReplyPublishQuota 在同一个事务内完成，结果区分“允许 / 额度已满或重复 /
//     额度服务暂不可用”，分别映射为继续创建 / 429 / 503。
//
// 保留本文件用于放置额度相关的 handler 级语义常量。

// errPostNotReplyable 表示事务内复核发现帖子已不可回复（治理隐藏或已删除）。
// 与入口的 409 语义一致，但由事务内复核触发，避免状态检查与写入之间的竞态。
var errPostNotReplyable = errors.New("post_not_replyable")
