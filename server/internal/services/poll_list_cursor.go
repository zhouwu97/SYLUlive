package services

import (
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
)

// pollCursorVersion 是翻页游标格式版本。
//
// 改字段含义必须递增：旧客户端带来的上一版游标会被判为失效并回到第一页，
// 而不是被错误解析成一个跳过/重复条目的位置。
const pollCursorVersion = "pc2"

// pollListCursor 是列表续页位置。
//
// 为什么不用 offset：并发新增会让「第 N 页」整体后移，同一条投票因此被跳过或重复，
// 用户看到的是列表自己在脚下动。latest/ending 直接用排序键做 keyset 续页；
// recommend 的顺序由互动数和时间评分决定，所以改成「池锚点 + 顺序摘要 + 池内下标」：
// 锚点排除新发布的投票，顺序摘要发现候选池或排名变化后让客户端回到第一页。
type pollListCursor struct {
	Sort string
	// KeyTime/KeyID 是 latest（created_at）或 ending（ends_at）的排序键位置。
	KeyTime time.Time
	KeyID   uint
	// PoolAnchorTime/PoolAnchorID 钉住推荐候选池的上边界（最新一条）。
	PoolAnchorTime time.Time
	PoolAnchorID   uint
	// PoolOrderHash 是推荐候选池排序后投票 ID 的摘要；排名变化时拒绝沿旧下标续页。
	PoolOrderHash string
	// Index 是推荐池内的下标偏移。
	Index int
}

// EncodePollListCursor 把续页位置编码成不透明字符串。
//
// 客户端只负责原样回传，不解析内容：位置格式因此可以独立演进。
func EncodePollListCursor(cursor pollListCursor) string {
	parts := []string{
		pollCursorVersion,
		cursor.Sort,
		strconv.FormatInt(cursor.KeyTime.UnixNano(), 10),
		strconv.FormatUint(uint64(cursor.KeyID), 10),
		strconv.FormatInt(cursor.PoolAnchorTime.UnixNano(), 10),
		strconv.FormatUint(uint64(cursor.PoolAnchorID), 10),
		cursor.PoolOrderHash,
		strconv.Itoa(cursor.Index),
	}
	return base64.RawURLEncoding.EncodeToString([]byte(strings.Join(parts, "|")))
}

// DecodePollListCursor 解析续页位置。任何解析失败或排序方式对不上都返回 ok=false，
// 调用方必须回退到第一页——一个解析错误的位置比没有位置更危险。
func DecodePollListCursor(encoded, sort string) (pollListCursor, bool) {
	var cursor pollListCursor
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return cursor, false
	}
	parts := strings.Split(string(raw), "|")
	if len(parts) != 8 || parts[0] != pollCursorVersion {
		return cursor, false
	}
	if parts[1] != sort {
		// 排序方式变了：位置不再有意义，宁可回到第一页也不要接上一条别的排序。
		return cursor, false
	}
	keyNanos, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return cursor, false
	}
	keyID, err := strconv.ParseUint(parts[3], 10, 64)
	if err != nil {
		return cursor, false
	}
	anchorNanos, err := strconv.ParseInt(parts[4], 10, 64)
	if err != nil {
		return cursor, false
	}
	anchorID, err := strconv.ParseUint(parts[5], 10, 64)
	if err != nil {
		return cursor, false
	}
	index, err := strconv.Atoi(parts[7])
	if err != nil || index < 0 {
		return cursor, false
	}
	if sort == "recommend" {
		if len(parts[6]) != 64 {
			return cursor, false
		}
		if _, err := hex.DecodeString(parts[6]); err != nil {
			return cursor, false
		}
	} else if parts[6] != "" {
		return cursor, false
	}
	cursor = pollListCursor{
		Sort:           parts[1],
		KeyTime:        time.Unix(0, keyNanos).UTC(),
		KeyID:          uint(keyID),
		PoolAnchorTime: time.Unix(0, anchorNanos).UTC(),
		PoolAnchorID:   uint(anchorID),
		PoolOrderHash:  parts[6],
		Index:          index,
	}
	return cursor, true
}

// pollKeysetBefore 是 (time, id) 的「严格排在它前面」条件（倒序续页用）。
//
// 不能只比时间：同一秒发布的投票在数据库里可以任意排，只按时间续页必然漏或重。
// 排序列和二级键列随排序方式不同（latest 用 posts.*，ending 用 polls.*），必须一起传。
func pollKeysetBefore(timeColumn, idColumn string) string {
	return "(" + timeColumn + " < ?) OR (" + timeColumn + " = ? AND " + idColumn + " < ?)"
}

// pollKeysetAfter 是 (time, id) 的「严格排在它后面」条件（升序续页用）。
func pollKeysetAfter(timeColumn, idColumn string) string {
	return "(" + timeColumn + " > ?) OR (" + timeColumn + " = ? AND " + idColumn + " > ?)"
}

// pollKeysetAtOrBefore 是「不晚于锚点」条件，用来钉住推荐候选池的上边界。
// 新发布的投票因此不会挤进已经翻过的页——这正是 offset 分页在并发新增下会漂的原因。
func pollKeysetAtOrBefore(timeColumn, idColumn string) string {
	return "(" + timeColumn + " < ?) OR (" + timeColumn + " = ? AND " + idColumn + " <= ?)"
}
