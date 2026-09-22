package models

// PublicPostStatuses 返回公共读取允许的正向状态白名单副本。
// 显式使用白名单而不是排除法：将来新增的帖子状态默认不公开，避免"先排除两个已知
// 状态再把未来状态全部放行"。帖子详情、投票、收藏、搜索等公共回读路径共用这一份定义，
// 任何一侧新增可见性判断时都不应再手抄状态列表。
func PublicPostStatuses() []PostStatus {
	return []PostStatus{PostStatusNormal, PostStatusSold, PostStatusClosed}
}

// IsPublicPostStatus 判断帖子当前状态是否可作为公共内容被读取和交互。
func IsPublicPostStatus(status PostStatus) bool {
	for _, public := range PublicPostStatuses() {
		if status == public {
			return true
		}
	}
	return false
}
