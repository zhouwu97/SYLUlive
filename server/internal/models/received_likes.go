package models

import (
	"reflect"

	"gorm.io/gorm"
)

// EffectiveReceivedLikes 是获赞总数与明细唯一的有效记录入口。
// 删除父帖会同时排除其评论获赞；保留点赞事实，使治理恢复后自然重新计入。
// 先按作者限定帖子/评论再合并，避免每次资料读取扫描整个点赞表。
func EffectiveReceivedLikes(db *gorm.DB, userIDs []uint) *gorm.DB {
	query := db.Session(&gorm.Session{NewDB: true})
	postLikes := query.Table("posts AS p").
		Select("pl.id, pl.user_id, pl.target_type, pl.target_id, pl.created_at, p.author_id, p.id AS post_id, p.title AS post_title").
		Joins("JOIN likes AS pl ON pl.target_type = 'post' AND pl.target_id = p.id").
		Where("p.author_id IN ? AND p.status IN ?", userIDs, PublicPostStatuses())
	replyLikes := query.Table("replies AS r").
		Select("rl.id, rl.user_id, rl.target_type, rl.target_id, rl.created_at, r.author_id, p.id AS post_id, p.title AS post_title").
		Joins("JOIN posts AS p ON p.id = r.post_id").
		Joins("JOIN likes AS rl ON rl.target_type = 'reply' AND rl.target_id = r.id").
		Where("r.author_id IN ? AND r.status = ? AND p.status IN ?", userIDs, ReplyStatusNormal, PublicPostStatuses())
	return query.Table("(? UNION ALL ?) AS l", postLikes, replyLikes).
		Joins("JOIN users AS u ON u.id = l.user_id").
		Where("l.user_id <> l.author_id").
		Where("u.account_status = ? OR u.account_status = ''", "active")
}

// ReceivedLikeCounts 一次汇总一批作者，缺少有效点赞的作者显式返回零。
func ReceivedLikeCounts(db *gorm.DB, userIDs []uint) (map[uint]int, error) {
	counts := make(map[uint]int, len(userIDs))
	for _, id := range userIDs {
		if id > 0 {
			counts[id] = 0
		}
	}
	if len(counts) == 0 {
		return counts, nil
	}
	ids := make([]uint, 0, len(counts))
	for id := range counts {
		ids = append(ids, id)
	}
	var rows []struct {
		AuthorID uint
		Total    int
	}
	err := EffectiveReceivedLikes(db, ids).
		Select("l.author_id, COUNT(*) AS total").Group("l.author_id").Scan(&rows).Error
	if err != nil {
		return nil, err
	}
	for _, row := range rows {
		counts[row.AuthorID] = row.Total
	}
	return counts, nil
}

// fillReceivedLikesAfterFind 批量填充当前这次用户查询，兼顾 Author 预载、搜索与资料。
// 不按每一条 User 再查一次，避免信息流出现 N+1 聚合查询。
func fillReceivedLikesAfterFind(tx *gorm.DB) error {
	if tx.Statement.CurDestIndex != 0 {
		return nil
	}
	columns, restricted := tx.Statement.SelectAndOmitColumns(false, false)
	included, specified := columns["total_likes_received"]
	if (restricted && !included) || (specified && !included) {
		return nil
	}
	var users []*User
	value := tx.Statement.ReflectValue
	appendUser := func(v reflect.Value) {
		if v.Kind() == reflect.Ptr {
			if v.IsNil() {
				return
			}
			v = v.Elem()
		}
		if v.CanAddr() {
			if u, ok := v.Addr().Interface().(*User); ok {
				users = append(users, u)
			}
		}
	}
	if value.Kind() == reflect.Slice || value.Kind() == reflect.Array {
		for i := 0; i < value.Len(); i++ {
			appendUser(value.Index(i))
		}
	} else {
		appendUser(value)
	}
	if len(users) == 0 {
		return nil
	}
	ids := make([]uint, 0, len(users))
	for _, u := range users {
		ids = append(ids, u.ID)
	}
	query := tx.Session(&gorm.Session{NewDB: true})
	// 最小账号库/尚未引入社区表的兼容环境没有点赞事实，不能沿用历史错计。
	if !query.Migrator().HasTable("likes") {
		for _, u := range users {
			u.TotalLikesReceived = 0
		}
		return nil
	}
	counts, err := ReceivedLikeCounts(query, ids)
	if err != nil {
		return err
	}
	for _, u := range users {
		u.TotalLikesReceived = counts[u.ID]
	}
	return nil
}
