//go:build integration

// 本文件验证内容发布额度在真实 PostgreSQL 上的原子性。
//
// 为什么必须用 PostgreSQL：
//   - SQLite 忽略 FOR NO KEY UPDATE，且单连接测试无法产生真实的行锁竞争；
//   - mock Count 或只跑 go test -race 都不能证明“检查 + 创建”在同一事务内不可交错。
//
// 运行方式（与 ci.yml 保持一致）：
//
//	TEST_DATABASE_DSN=postgres://... ALLOW_DESTRUCTIVE_INTEGRATION_TESTS=1 \
//	  go test -tags=integration ./internal/handlers -run 'PostPublishQuota|ReplyPostHidden'
package handlers

import (
	"context"
	"database/sql"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// openPostQuotaPG 使用独立连接池打开测试库。
// 每个调用都会得到**另一个** *gorm.DB / *sql.DB，用于验证“两个独立连接池共同写同一
// 数据库”这一场景不依赖单实例内存锁。
func openPostQuotaPG(t *testing.T, maxOpenConns int) *gorm.DB {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv("TEST_DATABASE_DSN"))
	if dsn == "" {
		t.Skip("TEST_DATABASE_DSN 未设置，跳过 PostgreSQL 发布额度并发集成测试")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(maxOpenConns)
	requireIntegrationTestDatabase(t, db)
	return db
}

func setupPostQuotaSchema(t *testing.T, db *gorm.DB) {
	t.Helper()
	require.NoError(t, db.AutoMigrate(
		&models.User{}, &models.Post{}, &models.PostImage{}, &models.File{}, &models.ImageVariant{},
		&models.Reply{}, &models.ReplyImage{},
	))
	// 破坏性清理仅作用于 *_test 数据库（requireIntegrationTestDatabase 已校验）。
	require.NoError(t, db.Exec(
		"TRUNCATE posts, post_images, replies, reply_images, files, image_variants, users RESTART IDENTITY CASCADE",
	).Error)
}

func seedQuotaPGUser(t *testing.T, db *gorm.DB, studentID string) models.User {
	t.Helper()
	user := models.User{StudentID: studentID, PasswordHash: "x", Nickname: "并发用户-" + studentID}
	require.NoError(t, db.Create(&user).Error)
	return user
}

func seedQuotaPGPost(t *testing.T, db *gorm.DB, authorID uint, status models.PostStatus, createdAt time.Time) models.Post {
	t.Helper()
	post := models.Post{
		Title: "预置", Content: "预置正文", BoardID: models.BoardScam, AuthorID: authorID,
		Status: status, CreatedAt: createdAt, LastActivityAt: createdAt,
	}
	require.NoError(t, db.Create(&post).Error)
	return post
}

// quotaStartBarrier 让所有并发请求在真正进入额度检查之前对齐。
//
// 为什么需要它：并发测试如果只依赖 goroutine 自然重叠，几十微秒的执行窗口经常
// 侥幸不重叠，导致“检查与写入分离”的实现也能通过。对齐之后，所有请求会在同一
// 时刻读到同一份未提交状态，从而确定性地暴露超发。
type quotaStartBarrierKey struct{}

type quotaStartBarrier struct {
	once    sync.Once
	arrived *sync.WaitGroup
	release chan struct{}
}

func newQuotaStartBarrier(total int, timeout time.Duration) *quotaStartBarrier {
	arrived := &sync.WaitGroup{}
	arrived.Add(total)
	barrier := &quotaStartBarrier{arrived: arrived, release: make(chan struct{})}
	go func() {
		done := make(chan struct{})
		go func() { arrived.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(timeout):
		}
		close(barrier.release)
	}()
	return barrier
}

// waitOnFirstQuery 是该请求的第一次数据库查询时执行一次；对齐后等待放行。
func (b *quotaStartBarrier) waitOnFirstQuery() {
	if b == nil {
		return
	}
	b.once.Do(func() {
		b.arrived.Done()
		<-b.release
	})
}

// installQuotaStartBarrier 在请求上下文里挂载对齐栅栏。
func installQuotaStartBarrier(db *gorm.DB) error {
	return db.Callback().Query().Before("gorm:query").Register("quota_start_barrier", func(tx *gorm.DB) {
		if tx.Statement == nil || tx.Statement.Context == nil {
			return
		}
		if barrier, ok := tx.Statement.Context.Value(quotaStartBarrierKey{}).(*quotaStartBarrier); ok {
			barrier.waitOnFirstQuery()
		}
	})
}

func createPostViaHandler(t *testing.T, h *PostHandler, userID uint, seed string, barrier *quotaStartBarrier) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	form := url.Values{}
	form.Set("title", "并发发帖-"+seed)
	form.Set("content", "并发内容-"+seed)
	form.Set("board_id", "3")
	req := httptest.NewRequest(http.MethodPost, "/api/posts", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if barrier != nil {
		req = req.WithContext(context.WithValue(req.Context(), quotaStartBarrierKey{}, barrier))
	}
	c.Request = req
	c.Set("user_id", userID)
	c.Set("role", "user")
	h.Create(c)
	return w
}

type quotaOutcome struct {
	created     int
	limited     int
	unavailable int
	other       int
	otherBodies []string
}

func classifyQuotaOutcomes(t *testing.T, results []*httptest.ResponseRecorder) quotaOutcome {
	t.Helper()
	var outcome quotaOutcome
	for _, w := range results {
		switch w.Code {
		case http.StatusCreated:
			outcome.created++
		case http.StatusTooManyRequests:
			outcome.limited++
		case http.StatusServiceUnavailable:
			outcome.unavailable++
		default:
			outcome.other++
			outcome.otherBodies = append(outcome.otherBodies, fmt.Sprintf("%d:%s", w.Code, w.Body.String()))
		}
	}
	return outcome
}

// RATE-02：同一用户 20 个并发、不同内容，成功数严格不超过剩余配额，且没有 500。
func TestPostPublishQuotaConcurrentSinglePool(t *testing.T) {
	db := openPostQuotaPG(t, 24)
	setupPostQuotaSchema(t, db)
	user := seedQuotaPGUser(t, db, "quota-single")

	// 预置 4 条窗口内的成功发表 → 短窗口剩余 2 条。
	const preexisting = 4
	now := time.Now()
	for i := 0; i < preexisting; i++ {
		seedQuotaPGPost(t, db, user.ID, models.PostStatusNormal, now.Add(-time.Duration(i)*time.Second))
	}

	h := NewPostHandler(db, "", "")
	const concurrency = 20
	require.NoError(t, installQuotaStartBarrier(db))
	barrier := newQuotaStartBarrier(concurrency, 10*time.Second)

	results := make([]*httptest.ResponseRecorder, concurrency)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			results[i] = createPostViaHandler(t, h, user.ID, fmt.Sprintf("single-%d", i), barrier)
		}(i)
	}
	close(start)
	wg.Wait()

	outcome := classifyQuotaOutcomes(t, results)
	require.Equal(t, services.PostPublishShortLimit-preexisting, outcome.created,
		"成功数必须严格等于剩余配额，不能超发：%v", outcome.otherBodies)
	require.Equal(t, concurrency-outcome.created, outcome.limited)
	require.Zero(t, outcome.unavailable, "不应出现额度服务暂不可用")
	require.Zero(t, outcome.other, "不应出现 500 等其它状态：%v", outcome.otherBodies)

	var total int64
	require.NoError(t, db.Model(&models.Post{}).Where("author_id = ?", user.ID).Count(&total).Error)
	require.EqualValues(t, services.PostPublishShortLimit, total, "数据库中的发表总数必须等于额度上限")
}

// RATE-03：两个完全独立的 *gorm.DB（各自连接池）共同写入同一测试数据库时，
// 仍然不能超过配额——正确性不能依赖单实例内存锁。
func TestPostPublishQuotaAcrossIndependentPools(t *testing.T) {
	primary := openPostQuotaPG(t, 12)
	setupPostQuotaSchema(t, primary)
	secondary := openPostQuotaPG(t, 12)

	user := seedQuotaPGUser(t, primary, "quota-pools")
	const preexisting = 4
	now := time.Now()
	for i := 0; i < preexisting; i++ {
		seedQuotaPGPost(t, primary, user.ID, models.PostStatusNormal, now.Add(-time.Duration(i)*time.Second))
	}

	handlersByPool := []*PostHandler{NewPostHandler(primary, "", ""), NewPostHandler(secondary, "", "")}
	const concurrency = 20
	require.NoError(t, installQuotaStartBarrier(primary))
	require.NoError(t, installQuotaStartBarrier(secondary))
	barrier := newQuotaStartBarrier(concurrency, 10*time.Second)

	results := make([]*httptest.ResponseRecorder, concurrency)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			h := handlersByPool[i%len(handlersByPool)]
			results[i] = createPostViaHandler(t, h, user.ID, fmt.Sprintf("pool-%d", i), barrier)
		}(i)
	}
	close(start)
	wg.Wait()

	outcome := classifyQuotaOutcomes(t, results)
	require.Equal(t, services.PostPublishShortLimit-preexisting, outcome.created,
		"跨连接池并发下不能超过配额：%v", outcome.otherBodies)
	require.Zero(t, outcome.other, "不应出现 500 等其它状态：%v", outcome.otherBodies)

	var total int64
	require.NoError(t, primary.Model(&models.Post{}).Where("author_id = ?", user.ID).Count(&total).Error)
	require.EqualValues(t, services.PostPublishShortLimit, total)
}

// RATE-08（用户维度）：并发发帖不得因为全局串行而互相挤压——不同账号的额度彼此独立，
// 各自都能在并发下用满自己的剩余配额。
func TestPostPublishQuotaConcurrentUsersAreIndependent(t *testing.T) {
	db := openPostQuotaPG(t, 24)
	setupPostQuotaSchema(t, db)

	const users = 4
	const perUser = 8
	userIDs := make([]uint, 0, users)
	for i := 0; i < users; i++ {
		userIDs = append(userIDs, seedQuotaPGUser(t, db, fmt.Sprintf("quota-user-%d", i)).ID)
	}

	h := NewPostHandler(db, "", "")
	total := users * perUser
	require.NoError(t, installQuotaStartBarrier(db))
	barrier := newQuotaStartBarrier(total, 10*time.Second)

	results := make([][]*httptest.ResponseRecorder, users)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for u := 0; u < users; u++ {
		results[u] = make([]*httptest.ResponseRecorder, perUser)
		for i := 0; i < perUser; i++ {
			wg.Add(1)
			go func(u, i int) {
				defer wg.Done()
				<-start
				results[u][i] = createPostViaHandler(t, h, userIDs[u], fmt.Sprintf("u%d-%d", u, i), barrier)
			}(u, i)
		}
	}
	close(start)
	wg.Wait()

	for u := 0; u < users; u++ {
		outcome := classifyQuotaOutcomes(t, results[u])
		require.Equal(t, services.PostPublishShortLimit, outcome.created,
			"用户 %d 应能独立用满自己的额度", u)
		require.Zero(t, outcome.other, "用户 %d 出现非预期状态：%v", u, outcome.otherBodies)
	}
}

// RATE-08（状态与锁顺序）：入口检查通过之后、事务内复核之前帖子被治理隐藏，
// 事务内复核必须能看到这次并发提交并拒绝写入，不能留下“已隐藏帖子下的新回复”。
func TestReplyRejectedWhenPostHiddenBeforeTransactionRecheck(t *testing.T) {
	db := openPostQuotaPG(t, 12)
	setupPostQuotaSchema(t, db)
	author := seedQuotaPGUser(t, db, "recheck-author")
	replier := seedQuotaPGUser(t, db, "recheck-replier")
	post := seedQuotaPGPost(t, db, author.ID, models.PostStatusNormal, time.Now())

	// 独立连接用于在事务中途改变帖子状态。
	otherConn, err := db.DB()
	require.NoError(t, err)

	var once sync.Once
	require.NoError(t, db.Callback().Query().Before("gorm:query").Register("hide_post_before_tx_recheck", func(tx *gorm.DB) {
		if tx.Statement == nil || tx.Statement.Table != "posts" {
			return
		}
		// 只拦截事务内的查询：入口检查走的是根连接的 *sql.DB。
		if _, inTx := tx.Statement.ConnPool.(*sql.Tx); !inTx {
			return
		}
		once.Do(func() {
			_, execErr := otherConn.Exec("UPDATE posts SET status = $1 WHERE id = $2", models.PostStatusModeratedHidden, post.ID)
			require.NoError(t, execErr)
		})
	}))

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	form := url.Values{}
	form.Set("content", "这条回复不应写入")
	req := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/api/posts/%d/replies", post.ID), strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	c.Request = req
	c.Params = gin.Params{{Key: "id", Value: fmt.Sprintf("%d", post.ID)}}
	c.Set("user_id", replier.ID)
	c.Set("role", "user")

	NewReplyHandler(db, "", "").Create(c)

	require.Equal(t, http.StatusConflict, w.Code, "事务内复核发现帖子已不可回复时必须拒绝：%s", w.Body.String())

	var replyCount int64
	require.NoError(t, db.Model(&models.Reply{}).Where("post_id = ?", post.ID).Count(&replyCount).Error)
	require.Zero(t, replyCount, "被拒绝的回复不得落库")

	var refreshed models.Post
	require.NoError(t, db.Select("id", "reply_count").First(&refreshed, post.ID).Error)
	require.Zero(t, refreshed.ReplyCount, "被拒绝的回复不得增加 reply_count")
}
