package handlers

import (
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// 公共帖子读取的可见性约束集中放置在本文件，避免各条回读路径各自使用
// `id IN (...)` 而丢掉状态判断。
//
// 安全底线：快照只保存帖子 ID，快照生成后帖子可能已被作者删除或被治理隐藏。
// 因此所有“按快照/按 ID 二次回读”的公共路径都必须在读取时重新判断**数据库当前
// 可见状态**，不能依赖快照生成时的过滤结果，也不能只依赖快照失效或 10 分钟过期。

// publicPostStatuses 是公共读取允许的正向状态白名单。
// 显式使用白名单而不是排除法：将来新增的状态默认不公开，避免“先排除两个已知
// 状态再把未来状态全部放行”。
var publicPostStatuses = []models.PostStatus{
	models.PostStatusNormal,
	models.PostStatusSold,
	models.PostStatusClosed,
}

// marketListingPostStatuses 是公共集市列表允许展示的状态。
// 已售商品仍需在详情、个人主页和“我的内容”中保留，但不再占用公共集市列表的位置。
var marketListingPostStatuses = []models.PostStatus{
	models.PostStatusNormal,
	models.PostStatusClosed,
}

// publicPostStatusesForBoard 返回指定板块的公共列表状态白名单。
// 未识别板块继续使用全局公共白名单，避免改变其他帖子列表的既有语义。
func publicPostStatusesForBoard(boardID *models.BoardID) []models.PostStatus {
	if boardID != nil && *boardID == models.BoardMarket {
		return marketListingPostStatuses
	}
	return publicPostStatuses
}

// homeFeedPostStatuses 是首页水帖综合/最新流的可见状态。
// 首页水帖只展示正常状态；集市可公开展示的 sold/closed 不等于首页也要展示全部状态。
var homeFeedPostStatuses = []models.PostStatus{
	models.PostStatusNormal,
}

// applyPublicPostStatus 给查询加上公共可见状态约束。
// statuses 为空时回退到 publicPostStatuses，保证任何调用点都不会退化成无约束查询。
func applyPublicPostStatus(query *gorm.DB, statuses []models.PostStatus) *gorm.DB {
	if len(statuses) == 0 {
		statuses = publicPostStatuses
	}
	return query.Where("posts.status IN ?", statuses)
}

// feedWindow 描述按原始候选顺序切出的一页。
type feedWindow struct {
	Start      int
	End        int
	NextOffset int
	HasMore    bool
}

// sliceFeedWindow 以“先验证 offset，再计算 remaining，最后取 min”的方式切片，
// 避免 `offset + limit` 先相加再 clamp 造成的溢出与负数索引。
// offset 允许等于或超过候选长度，此时返回空窗口且 HasMore=false。
func sliceFeedWindow(candidateCount, offset, limit int) feedWindow {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 {
		limit = 1
	}
	if offset >= candidateCount {
		return feedWindow{Start: candidateCount, End: candidateCount, NextOffset: candidateCount, HasMore: false}
	}
	remaining := candidateCount - offset
	size := limit
	if remaining < size {
		size = remaining
	}
	end := offset + size
	return feedWindow{Start: offset, End: end, NextOffset: end, HasMore: end < candidateCount}
}

// paginationMetaCapability 是客户端声明“能识别 next_offset/has_more 分页元数据”的能力项。
// 旧客户端不声明该能力：当可见性过滤导致短页时无法按原始候选位置推进，
// 继续按已显示条数推进会重复扫描甚至空转，因此返回 409 让客户端刷新列表。
const paginationMetaCapability = "feed_pagination_meta_v1"

// supportsFeedPaginationMeta 判断请求是否声明支持分页元数据。
func supportsFeedPaginationMeta(c *gin.Context) bool {
	for _, capability := range strings.Split(c.Query("capabilities"), ",") {
		if strings.TrimSpace(capability) == paginationMetaCapability {
			return true
		}
	}
	return false
}

// snapshotFilterKey 生成快照的筛选指纹。
// loadmore 时筛选条件（版块/类型/排序/标签/话题/搜索/增量）必须与生成快照时一致，
// 否则不能复用同一份 ID 列表，避免把另一个上下文的内容返回给当前请求。
// 直接使用原始查询字符串，不做数值归一化，保证 tag_id=007 与 tag_id=7 不会
// 被错误地当作同一筛选上下文。
func snapshotFilterKey(c *gin.Context) string {
	return strings.Join([]string{
		strings.TrimSpace(c.Query("board")),
		strings.TrimSpace(c.Query("type")),
		strings.TrimSpace(c.DefaultQuery("sort", "time")),
		strings.TrimSpace(c.Query("tag_id")),
		strings.TrimSpace(c.Query("topic_id")),
		strings.TrimSpace(strings.ToLower(c.Query("q"))),
		strings.TrimSpace(c.Query("since")),
	}, "|")
}

// snapshotUsable 判断快照是否可用于本次 loadmore 请求。
// 空 FilterKey 表示该快照由旧路径或测试直接写入，此时不做筛选指纹校验，
// 避免把既有测试与历史快照全部判为不可用。
func snapshotUsable(snapshot *Snapshot, feedKind, filterKey string, userID uint) bool {
	if snapshot.FeedKind != feedKind {
		return false
	}
	if snapshot.FilterKey != "" && snapshot.FilterKey != filterKey {
		return false
	}
	if snapshot.UserID != userID {
		return false
	}
	return true
}
