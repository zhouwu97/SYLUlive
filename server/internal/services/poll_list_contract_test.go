package services

import (
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	gormlogger "gorm.io/gorm/logger"
)

// newPollListTestDB 与投票服务测试库同构，但把 gorm 日志调到 Silent：
// 这里要跑 500 条候选池的翻页，逐条 SQL 日志会把断言输出埋掉。
func newPollListTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "poll-list-contract.db")),
		&gorm.Config{Logger: gormlogger.Default.LogMode(gormlogger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(
		&models.User{}, &models.Topic{}, &models.PostTopic{}, &models.File{}, &models.FileUploadGrant{},
		&models.Post{}, &models.PostImage{}, &models.ImageVariant{}, &models.Poll{}, &models.PollOption{},
		&models.PollBallot{}, &models.PollBallotChoice{},
	); err != nil {
		t.Fatal(err)
	}
	return db
}

// A13：投票列表的分页契约（POL-07 ~ POL-10）。
// 这些用例钉住的是「total / has_more / 候选池」三者必须互相自洽，
// 而不是某一页里具体有哪些投票。

// pollListPayload 把结果按真实 HTTP 响应的形状序列化后再读回，
// 这样「服务端根本没有返回 has_more」这种旧行为会作为断言失败出现，
// 而不是编译期就依赖新字段存在。
func pollListPayload(t *testing.T, result PollListResult) map[string]interface{} {
	t.Helper()
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]interface{}
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func requireListInt64(t *testing.T, payload map[string]interface{}, key string) int64 {
	t.Helper()
	value, ok := payload[key]
	if !ok {
		t.Fatalf("分页响应缺少 %q 字段，客户端无法区分“可分页候选总数”和“全站匹配数量”：%v", key, payload)
	}
	number, ok := value.(float64)
	if !ok {
		t.Fatalf("%q 不是数字：%v", key, value)
	}
	return int64(number)
}

func requireListBool(t *testing.T, payload map[string]interface{}, key string) bool {
	t.Helper()
	value, ok := payload[key]
	if !ok {
		t.Fatalf("分页响应缺少 %q 字段，只能由客户端按“本页长度等于 limit”猜是否还能翻页", key)
	}
	flag, ok := value.(bool)
	if !ok {
		t.Fatalf("%q 不是布尔值：%v", key, value)
	}
	return flag
}

type pollRowFixture struct {
	createdAt    time.Time
	endsAt       time.Time
	pollStatus   string
	postStatus   models.PostStatus
	participants int
}

// seedPollRows 批量落库，绕开发布额度，只构造列表读取需要的最小字段。
// 不建选项：推荐分数与分页契约都不依赖选项内容。
func seedPollRows(t *testing.T, db *gorm.DB, authorID uint, fixtures []pollRowFixture) []uint {
	t.Helper()
	posts := make([]models.Post, 0, len(fixtures))
	for _, fixture := range fixtures {
		status := fixture.postStatus
		if status == "" {
			status = models.PostStatusNormal
		}
		posts = append(posts, models.Post{
			Title: "分页契约投票", Content: "说明", BoardID: models.BoardShuitie, AuthorID: authorID,
			PostType: "poll", ContentKind: models.PostContentKindPoll, Status: status,
			CreatedAt: fixture.createdAt, LastActivityAt: fixture.createdAt,
		})
	}
	if err := db.Create(&posts).Error; err != nil {
		t.Fatal(err)
	}
	polls := make([]models.Poll, 0, len(fixtures))
	for i, fixture := range fixtures {
		pollStatus := fixture.pollStatus
		if pollStatus == "" {
			pollStatus = models.PollStatusActive
		}
		polls = append(polls, models.Poll{
			PostID: posts[i].ID, Category: models.PollCategoryOther, SelectionMode: models.PollSelectionSingle,
			MaxChoices: 1, ResultsVisibility: models.PollResultsAlways, AllowChange: true,
			IsAnonymous: true, Status: pollStatus, EndsAt: fixture.endsAt,
			ParticipantCount: fixture.participants, CreatedAt: fixture.createdAt,
		})
	}
	if err := db.Create(&polls).Error; err != nil {
		t.Fatal(err)
	}
	postIDs := make([]uint, 0, len(posts))
	for _, post := range posts {
		postIDs = append(postIDs, post.ID)
	}
	return postIDs
}

func activePollRows(count int, firstCreatedAt time.Time, step time.Duration) []pollRowFixture {
	rows := make([]pollRowFixture, 0, count)
	for i := 0; i < count; i++ {
		created := firstCreatedAt.Add(time.Duration(i) * step)
		rows = append(rows, pollRowFixture{createdAt: created, endsAt: created.Add(72 * time.Hour)})
	}
	return rows
}

func postIDsOf(result PollListResult) []uint {
	ids := make([]uint, 0, len(result.Items))
	for _, post := range result.Items {
		ids = append(ids, post.ID)
	}
	return ids
}

// listAllPages 按服务端 has_more 翻页到底，返回去重后的条目数、重复次数与请求页数。
// 循环有硬上限：如果 has_more 自相矛盾，测试必须失败而不是无限翻页。
func listAllPages(t *testing.T, service *PollService, input PollListInput) (ids []uint, pages int, seen map[uint]int) {
	t.Helper()
	seen = map[uint]int{}
	input.UserID = 0
	for page := 1; page <= 200; page++ {
		current := input
		current.Page = page
		result, err := service.List(current, current.UserID)
		if err != nil {
			t.Fatalf("第 %d 页读取失败：%v", page, err)
		}
		pages = page
		for _, id := range postIDsOf(result) {
			seen[id]++
			if seen[id] > 1 {
				t.Fatalf("帖子 %d 在第 %d 页重复出现（跨页遗漏或重复）", id, page)
			}
			ids = append(ids, id)
		}
		if !requireListBool(t, pollListPayload(t, result), "has_more") {
			return ids, pages, seen
		}
		if len(result.Items) == 0 {
			t.Fatalf("第 %d 页为空但 has_more 仍为 true，客户端会一直翻页下去", page)
		}
	}
	t.Fatalf("翻页 200 页仍未收敛，has_more 与候选池不自洽")
	return nil, 0, nil
}

// POL-07：ending 的 total 只统计满足 ending 条件的条目，而且 ending 过滤必须先于 Count。
func TestPollListEndingTotalOnlyCountsEndingPolls(t *testing.T) {
	db := newPollListTestDB(t)
	now := time.Date(2026, 9, 21, 12, 0, 0, 0, time.Local)
	owner := seedPollUser(t, db, "ending-total")
	// 四条公开投票：只有第一条是「进行中且未截止」。
	seedPollRows(t, db, owner.ID, []pollRowFixture{
		{createdAt: now.Add(-time.Hour), endsAt: now.Add(time.Hour)},
		{createdAt: now.Add(-2 * time.Hour), endsAt: now.Add(-time.Minute)},
		{createdAt: now.Add(-3 * time.Hour), endsAt: now.Add(time.Hour), pollStatus: models.PollStatusClosed},
		{createdAt: now.Add(-4 * time.Hour), endsAt: now.Add(time.Hour), postStatus: models.PostStatusModeratedHidden},
	})
	service := NewPollService(db)
	service.SetNowForTest(func() time.Time { return now })

	ending, err := service.List(PollListInput{Sort: "ending", Page: 1, Limit: 10}, 0)
	if err != nil {
		t.Fatal(err)
	}
	payload := pollListPayload(t, ending)
	if len(ending.Items) != 1 {
		t.Fatalf("ending 结果集 = %v，期望只有 1 条", postIDsOf(ending))
	}
	if total := requireListInt64(t, payload, "total"); total != 1 {
		t.Fatalf("ending total = %d，但它统计的是全部匹配投票而不是可翻页的 ending 集合", total)
	}
	if matched := requireListInt64(t, payload, "matched_total"); matched != 1 {
		t.Fatalf("ending matched_total = %d，说明 ending 过滤没有进入基础查询", matched)
	}
	if requireListBool(t, payload, "has_more") {
		t.Fatal("ending 只剩 1 条时 has_more 仍为 true")
	}

	latest, err := service.List(PollListInput{Sort: "latest", Page: 1, Limit: 10}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if total := requireListInt64(t, pollListPayload(t, latest), "total"); total != 3 {
		t.Fatalf("latest total = %d，公开投票应为 3（隐藏的不得计入）", total)
	}
}

// POL-08：候选条数超过推荐池时，池、total 与 has_more 必须自洽，且不得出现空页。
func TestPollListRecommendPoolKeepsTotalAndHasMoreConsistent(t *testing.T) {
	db := newPollListTestDB(t)
	now := time.Date(2026, 9, 21, 12, 0, 0, 0, time.Local)
	owner := seedPollUser(t, db, "recommend-pool")
	const candidates = 530
	postIDs := seedPollRows(t, db, owner.ID, activePollRows(candidates, now.Add(-24*time.Hour), time.Minute))
	newest := postIDs[len(postIDs)-1]
	service := NewPollService(db)
	service.SetNowForTest(func() time.Time { return now })

	first, err := service.List(PollListInput{Sort: "recommend", Page: 1, Limit: 20}, 0)
	if err != nil {
		t.Fatal(err)
	}
	payload := pollListPayload(t, first)
	poolSize := requireListInt64(t, payload, "pool_size")
	if poolSize != pollRecommendPoolSize {
		t.Fatalf("推荐池大小 = %d，期望 %d", poolSize, pollRecommendPoolSize)
	}
	if matched := requireListInt64(t, payload, "matched_total"); matched != candidates {
		t.Fatalf("matched_total = %d，期望全站匹配 %d", matched, candidates)
	}
	// total 表示「这次请求能翻到的候选数」，必须等于实际入池条数，
	// 否则旧客户端按 total 判断的进度条会永远走不到底。
	if total := requireListInt64(t, payload, "total"); total != pollRecommendPoolSize {
		t.Fatalf("recommend total = %d，但候选池只装载 %d 条，超出的部分永远翻不到", total, pollRecommendPoolSize)
	}
	if !requireListBool(t, payload, "has_more") {
		t.Fatal("候选池首页之后仍有内容，has_more 却为 false")
	}

	ids, pages, _ := listAllPages(t, service, PollListInput{Sort: "recommend", Limit: 20})
	if int64(len(ids)) != pollRecommendPoolSize {
		t.Fatalf("翻到底共读到 %d 条，候选池应有 %d 条", len(ids), pollRecommendPoolSize)
	}
	if pages != pollRecommendPoolSize/20 {
		t.Fatalf("翻页数 = %d，期望 %d", pages, pollRecommendPoolSize/20)
	}
	// 池是「最近 500 条」，最新一条必须在池内；不在池内就意味着候选池没有稳定顺序可言。
	found := false
	for _, id := range ids {
		if id == newest {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("最新投票未进入推荐候选池")
	}

	// 陈旧页（数据变动后旧进度落到的位置）必须明确告知「已到底」，而不是继续 has_more。
	stale, err := service.List(PollListInput{Sort: "recommend", Page: pages + 5, Limit: 20}, 0)
	if err != nil {
		t.Fatal(err)
	}
	stalePayload := pollListPayload(t, stale)
	if len(stale.Items) != 0 {
		t.Fatalf("陈旧页仍返回 %d 条", len(stale.Items))
	}
	if requireListBool(t, stalePayload, "has_more") {
		t.Fatal("超出候选池的页仍声明 has_more，客户端会翻到空页为止")
	}
}

// POL-09：同分/同时间的数据用 id 作稳定二级键，跨页不重复不遗漏，刷新后顺序可解释。
func TestPollListUsesIDAsStableTiebreaker(t *testing.T) {
	db := newPollListTestDB(t)
	now := time.Date(2026, 9, 21, 12, 0, 0, 0, time.Local)
	owner := seedPollUser(t, db, "tiebreaker")
	sameInstant := make([]pollRowFixture, 25)
	for i := range sameInstant {
		sameInstant[i] = pollRowFixture{createdAt: now.Add(-time.Hour), endsAt: now.Add(24 * time.Hour)}
	}
	seedPollRows(t, db, owner.ID, sameInstant)
	service := NewPollService(db)
	service.SetNowForTest(func() time.Time { return now })

	for _, sort := range []string{"latest", "recommend"} {
		t.Run(sort, func(t *testing.T) {
			ids, _, _ := listAllPages(t, service, PollListInput{Sort: sort, Limit: 10})
			if len(ids) != 25 {
				t.Fatalf("%s 翻到底共 %d 条，期望 25", sort, len(ids))
			}
			// 同创建时间时必须按 id 倒序，刷新后才是同一份可解释的顺序。
			for i := 1; i < len(ids); i++ {
				if ids[i-1] <= ids[i] {
					t.Fatalf("%s 同分数据未按 id 倒序排列：%v", sort, ids)
				}
			}
			repeat, err := service.List(PollListInput{Sort: sort, Page: 1, Limit: 10}, 0)
			if err != nil {
				t.Fatal(err)
			}
			repeated := postIDsOf(repeat)
			for i, id := range repeated {
				if id != ids[i] {
					t.Fatalf("%s 首页第 %d 条在刷新后变化：%v -> %v", sort, i, ids[:10], repeated)
				}
			}
		})
	}
}

// POL-10：治理隐藏的投票不得在任意一页回读泄露，也不得占用总数。
func TestPollListNeverLeakesHiddenPollsAcrossPages(t *testing.T) {
	db := newPollListTestDB(t)
	now := time.Date(2026, 9, 21, 12, 0, 0, 0, time.Local)
	owner := seedPollUser(t, db, "hidden-leak")
	visible := seedPollRows(t, db, owner.ID, activePollRows(5, now.Add(-10*time.Hour), time.Hour))
	// 最新的一条被隐藏：它若进入结果集只会出现在首页最前面，是最容易泄露的位置。
	hidden := seedPollRows(t, db, owner.ID, []pollRowFixture{{
		createdAt: now.Add(time.Minute), endsAt: now.Add(48 * time.Hour), postStatus: models.PostStatusModeratedHidden,
	}})
	service := NewPollService(db)
	service.SetNowForTest(func() time.Time { return now })

	for _, sort := range []string{"latest", "recommend", "ending"} {
		ids, _, _ := listAllPages(t, service, PollListInput{Sort: sort, Limit: 2})
		for _, id := range ids {
			for _, hiddenID := range hidden {
				if id == hiddenID {
					t.Fatalf("%s 第若干页泄露了隐藏投票 %d", sort, hiddenID)
				}
			}
		}
		if int64(len(ids)) != int64(len(visible)) {
			t.Fatalf("%s 翻到底得到 %d 条，公开投票只有 %d 条", sort, len(ids), len(visible))
		}
	}
}
