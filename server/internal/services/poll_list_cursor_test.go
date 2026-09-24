package services

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"shenliyuan/internal/models"
)

// 游标必须能原样往返；排序方式对不上或格式变了都必须判失效，
// 宁可回到第一页，也不能拿一个错位的位置往下翻。
func TestPollListCursorRoundTripAndInvalid(t *testing.T) {
	keyTime := time.Date(2026, 9, 22, 8, 30, 0, 0, time.UTC)
	anchor := keyTime.Add(-2 * time.Hour)
	for _, sort := range []string{"latest", "ending", "recommend"} {
		poolOrderHash := ""
		if sort == "recommend" {
			poolOrderHash = strings.Repeat("a", 64)
		}
		poolIDs := ""
		if sort == "recommend" {
			poolIDs = "1,2,3"
		}
		encoded := EncodePollListCursor(pollListCursor{
			Sort: sort, KeyTime: keyTime, KeyID: 42,
			PoolAnchorTime: anchor, PoolAnchorID: 7, PoolOrderHash: poolOrderHash, PoolIDs: poolIDs, Index: 20,
		})
		decoded, ok := DecodePollListCursor(encoded, sort)
		if !ok {
			t.Fatalf("%s 游标未能往返", sort)
		}
		if !decoded.KeyTime.Equal(keyTime) || decoded.KeyID != 42 ||
			!decoded.PoolAnchorTime.Equal(anchor) || decoded.PoolAnchorID != 7 || decoded.Index != 20 {
			t.Fatalf("%s 往返后字段被改写: %+v", sort, decoded)
		}
		if _, ok := DecodePollListCursor(encoded, "another-sort"); ok {
			t.Fatalf("%s 游标被另一套排序接受", sort)
		}
	}

	wrongVersion := base64.RawURLEncoding.EncodeToString([]byte("pc9|latest|1|1|0|0|0"))
	shortFields := base64.RawURLEncoding.EncodeToString([]byte("pc1|latest|1"))
	for _, bad := range []string{"", "not-base64!!", wrongVersion, shortFields} {
		if _, ok := DecodePollListCursor(bad, "latest"); ok {
			t.Fatalf("非法游标被接受: %q", bad)
		}
	}
	// 负下标在编码端写得出来，解码必须拒绝：它会把客户端带回一个不存在的位置。
	if _, ok := DecodePollListCursor(EncodePollListCursor(pollListCursor{Sort: "latest", Index: -1}), "latest"); ok {
		t.Fatal("负下标游标被接受")
	}
}

func TestPollListRecommendCursorSkipsDeletedSnapshotItemsWithoutReset(t *testing.T) {
	db := newPollListTestDB(t)
	base := time.Date(2026, 9, 22, 8, 0, 0, 0, time.UTC)
	seedPollRows(t, db, 1, activePollRows(6, base, time.Minute))
	service := NewPollService(db)

	first, err := service.List(PollListInput{Sort: "recommend", Page: 1, Limit: 2}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if first.NextCursor == "" {
		t.Fatal("推荐首页应生成快照游标")
	}
	// 删除首页后的第一条，旧实现会让第二页的下标左移，导致漏掉一条。
	firstIDs := postIDsOf(first)
	if len(firstIDs) == 0 {
		t.Fatal("推荐首页不应为空")
	}
	if err := db.Delete(&models.Post{}, firstIDs[0]).Error; err != nil {
		t.Fatal(err)
	}
	second, err := service.List(PollListInput{Sort: "recommend", Page: 2, Limit: 2, Cursor: first.NextCursor}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if second.CursorStale {
		t.Fatal("删除快照条目不应强制回到第一页")
	}
	for _, id := range postIDsOf(second) {
		if id == firstIDs[0] {
			t.Fatalf("已删除的快照条目仍出现在第二页: %v", postIDsOf(second))
		}
	}
}

// 并发新增不得让已翻过的条目重复出现，也不得让下一页漏掉本该出现的条目。
// 这正是 offset 分页的失效模式：新条目把「第 N 页」整体往后推了一格。
func TestPollListCursorContinuesWithoutSkipOrDuplicateWhenPostsArrive(t *testing.T) {
	db := newPollListTestDB(t)
	base := time.Date(2026, 9, 22, 8, 0, 0, 0, time.UTC)
	originalIDs := seedPollRows(t, db, 1, activePollRows(5, base, time.Minute))
	service := NewPollService(db)

	first, err := service.List(PollListInput{Sort: "latest", Page: 1, Limit: 2}, 0)
	if err != nil {
		t.Fatal(err)
	}
	firstIDs := postIDsOf(first)
	if len(firstIDs) != 2 || first.NextCursor == "" || !first.HasMore {
		t.Fatalf("首页应给出续页游标: ids=%v cursor=%q hasMore=%v", firstIDs, first.NextCursor, first.HasMore)
	}

	// 翻页途中插入两条更新的投票：offset 路径会把第 2 页整体后移，
	// 于是首页出现过的两条再次出现，而本该出现的两条被跳过。
	insertedIDs := seedPollRows(t, db, 1, activePollRows(2, base.Add(10*time.Minute), time.Minute))

	second, err := service.List(PollListInput{Sort: "latest", Page: 2, Limit: 2, Cursor: first.NextCursor}, 0)
	if err != nil {
		t.Fatal(err)
	}
	secondIDs := postIDsOf(second)
	if len(secondIDs) != 2 {
		t.Fatalf("第二页条数 = %v", secondIDs)
	}
	seen := map[uint]bool{}
	for _, id := range firstIDs {
		seen[id] = true
	}
	for _, id := range secondIDs {
		if seen[id] {
			t.Fatalf("第二页重复了首页已出现的投票 %d: %v / %v", id, firstIDs, secondIDs)
		}
		seen[id] = true
	}
	if second.HasMore && second.NextCursor == "" {
		t.Fatal("还有下一页却没有游标")
	}

	// 第三页继续沿着同一把游标走：三页合起来既不能多也不能少。
	third, err := service.List(PollListInput{Sort: "latest", Page: 3, Limit: 2, Cursor: second.NextCursor}, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range postIDsOf(third) {
		if seen[id] {
			t.Fatalf("第三页重复出现 %d: %v / %v / %v", id, firstIDs, secondIDs, postIDsOf(third))
		}
		seen[id] = true
	}
	// 续页沿着「比上一页末条更旧」走，因此翻到的必须正好是插入前那一批，
	// 新插入的两条留给下一次刷新——它们不该偷偷挤进已经定好的位置。
	if len(seen) != len(originalIDs) {
		t.Fatalf("三页合计 %d 条，期望插入前的 %d 条: %v", len(seen), len(originalIDs), seen)
	}
	for _, id := range insertedIDs {
		if seen[id] {
			t.Fatalf("翻页途中新插入的投票 %d 挤进了已定好的续页位置: %v", id, seen)
		}
	}
}

// ending 走 polls.ends_at 升序，二级键同样是 posts.id，游标必须跟着这条排序走。
func TestPollListCursorContinuesEndingOrder(t *testing.T) {
	db := newPollListTestDB(t)
	base := time.Date(2026, 9, 22, 8, 0, 0, 0, time.UTC)
	seedPollRows(t, db, 1, activePollRows(4, base, time.Minute))
	service := NewPollService(db)

	first, err := service.List(PollListInput{Sort: "ending", Page: 1, Limit: 2}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(postIDsOf(first)) != 2 || first.NextCursor == "" {
		t.Fatalf("ending 首页应给出游标: %v", postIDsOf(first))
	}
	// 插入一条截止更早的投票：offset 会把它顶到已翻过的页里造成重复。
	seedPollRows(t, db, 1, []pollRowFixture{{createdAt: base, endsAt: base.Add(time.Minute)}})

	second, err := service.List(PollListInput{Sort: "ending", Page: 2, Limit: 2, Cursor: first.NextCursor}, 0)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[uint]bool{}
	for _, id := range postIDsOf(first) {
		seen[id] = true
	}
	for _, id := range postIDsOf(second) {
		if seen[id] {
			t.Fatalf("ending 第二页重复 %d", id)
		}
	}
}

// 推荐池用锚点钉住上边界：新发布的投票不会挤进已经翻过的页。
func TestPollListRecommendCursorPinsPoolAgainstNewArrivals(t *testing.T) {
	db := newPollListTestDB(t)
	base := time.Date(2026, 9, 22, 8, 0, 0, 0, time.UTC)
	seedPollRows(t, db, 1, activePollRows(5, base, time.Minute))
	service := NewPollService(db)

	first, err := service.List(PollListInput{Sort: "recommend", Page: 1, Limit: 2}, 0)
	if err != nil {
		t.Fatal(err)
	}
	firstIDs := postIDsOf(first)
	if len(firstIDs) != 2 || first.NextCursor == "" {
		t.Fatalf("推荐首页应给出游标: %v cursor=%q", firstIDs, first.NextCursor)
	}

	seedPollRows(t, db, 1, activePollRows(3, base.Add(20*time.Minute), time.Minute))

	second, err := service.List(PollListInput{Sort: "recommend", Page: 2, Limit: 2, Cursor: first.NextCursor}, 0)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[uint]bool{}
	for _, id := range firstIDs {
		seen[id] = true
	}
	for _, id := range postIDsOf(second) {
		if seen[id] {
			t.Fatalf("推荐第二页重复了首页条目 %d: %v / %v", id, firstIDs, postIDsOf(second))
		}
	}
	if second.PoolSize != pollRecommendPoolSize {
		t.Fatalf("pool_size = %d", second.PoolSize)
	}
}

// 位置失效时必须显式回到第一页，让客户端整体替换而不是接着往下拼。
func TestPollListCursorStaleFallsBackToFirstPage(t *testing.T) {
	db := newPollListTestDB(t)
	base := time.Date(2026, 9, 22, 8, 0, 0, 0, time.UTC)
	seedPollRows(t, db, 1, activePollRows(4, base, time.Minute))
	service := NewPollService(db)

	wrongVersion := base64.RawURLEncoding.EncodeToString([]byte("pc9|latest|1|1|0|0|0"))
	for _, cursor := range []string{"garbage", wrongVersion} {
		result, err := service.List(PollListInput{Sort: "latest", Page: 3, Limit: 2, Cursor: cursor}, 0)
		if err != nil {
			t.Fatal(err)
		}
		if !result.CursorStale {
			t.Fatalf("游标 %q 失效应标记 cursor_stale", cursor)
		}
		if result.Page != 1 {
			t.Fatalf("游标失效后应回到第一页，实际 page=%d", result.Page)
		}
		if len(postIDsOf(result)) != 2 {
			t.Fatalf("失效游标应返回第一页数据: %v", postIDsOf(result))
		}
	}
}
